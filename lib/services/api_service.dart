import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../screens/login_screen.dart';

/// Standardized Response Object for all API calls
class ApiResponse {
  final bool success;
  final dynamic data;
  final String message;

  ApiResponse({required this.success, this.data, required this.message});

  @override
  String toString() =>
      'ApiResponse(success: $success, message: $message, data: $data)';
}

/// Centralized API Service Layer for Field Track
class ApiService {
  // Base URL Configuration (Cached from SharedPreferences for background isolate safety)
  String _baseUrl = "";
  static String _forcedBaseUrl = "";

  final bool isBackground;
  String get baseUrl => _baseUrl;

  ApiService({this.isBackground = false}) {
    _initBaseUrl();
  }

  Future<void> _initBaseUrl() async {
    try {
      // 1. Try Loading from dotenv
      _baseUrl = dotenv.env['BASE_URL'] ?? "";

      // 2. Fallback to SharedPreferences (Background Isolate)
      if (_baseUrl.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload(); // Ensure we see latest data
        _baseUrl = prefs.getString('api_base_url') ?? "";
      }
    } catch (e) {
      debugPrint('[API] Failed to load Base URL: $e');
    }
  }

  /// Helper to ensure URL is ready before request
  Future<String> _getValidBaseUrl() async {
    if (_baseUrl.isEmpty) await _initBaseUrl();
    return _baseUrl;
  }

  // Timeout duration
  static const Duration _timeout = Duration(seconds: 15);

  // Prevent multiple concurrent refreshes
  bool _isRefreshing = false;

  /// Private method to get common headers with JWT authentication
  Future<Map<String, String>> _getHeaders({bool isAuth = false}) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // Ensure background isolate sees latest tokens
    final String? token = prefs.getString('auth_token');

    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      // DO NOT send authorization header if we are performing an auth action (like login)
      if (token != null && !isAuth) 'Authorization': 'Bearer $token',
    };
  }

  /// Reusable request handler with centralized error handling and retry logic
  Future<ApiResponse> _sendRequest(
    Future<http.Response> Function() request, {
    bool canRetry = true,
    bool isAuth = false,
  }) async {
    try {
      debugPrint('[API] we are in send_request');
      final response = await request().timeout(_timeout);
      debugPrint(
        '[API] ${response.request?.method} to ${response.request?.url} -> ${response.statusCode}',
      );

      // Handle 401 Unauthorized specifically for retry logic
      if (response.statusCode == 401 && canRetry && !isAuth) {
        final refreshSuccess = await _attemptTokenRefresh();
        if (refreshSuccess) {
          return await _sendRequest(request, canRetry: false, isAuth: isAuth);
        }
      }

      return _processResponse(response, isAuth: isAuth);
    } on SocketException {
      return ApiResponse(success: false, message: 'No internet connection.');
    } on TimeoutException {
      return ApiResponse(success: false, message: 'Request timed out.');
    } catch (e) {
      debugPrint('[API Error] $e');
      return ApiResponse(
        success: false,
        message: 'Connection error: ${e.toString()}',
      );
    }
  }

  /// Internal logic to refresh tokens without recursion
  Future<bool> _attemptTokenRefresh() async {
    if (_isRefreshing) return false;
    _isRefreshing = true;

    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? refreshToken = prefs.getString('refresh_token');

      if (refreshToken == null) return false;

      final response = await http
          .post(
            Uri.parse('$_baseUrl/auth/refresh'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'refresh_token': refreshToken}),
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final body = json.decode(response.body);
        final String? newAccess =
            body['access_token'] ??
            (body['data'] != null ? body['data']['access_token'] : null);
        final String? newRefresh =
            body['refresh_token'] ??
            (body['data'] != null ? body['data']['refresh_token'] : null);

        if (newAccess != null) {
          await prefs.setString('auth_token', newAccess);
          if (newRefresh != null) {
            await prefs.setString('refresh_token', newRefresh);
          }
          return true;
        }
      }

      // If we reach here, refresh failed (user might be deleted or token expired)
      _forceLogout();
      return false;
    } catch (e) {
      return false;
    } finally {
      _isRefreshing = false;
    }
  }

  /// Clears session and redirects to login
  void _forceLogout() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();

    // 1. Clear all session data
    await prefs.remove('auth_token');
    await prefs.remove('refresh_token');
    await prefs.remove('active_journey_id');
    await prefs.remove('selected_company_id');

    // 2. Stop the background service if it's running
    try {
      final service = FlutterBackgroundService();
      if (await service.isRunning()) {
        service.invoke("stopService");
      }
    } catch (e) {
      debugPrint("Error stopping background service: $e");
    }

    // 3. Clear the navigation stack and go to Login (ONLY if NOT in background)
    if (!isBackground) {
      navigatorKey.currentState?.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    } else {
      debugPrint('[API] Force logout requested in background. Skipping UI redirect.');
    }
  }

  /// Stops tracking service and clears journey state without logging out
  void _stopBackgroundJourney() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove('active_journey_id');

    try {
      final service = FlutterBackgroundService();
      if (await service.isRunning()) {
        service.invoke("stopService");
        debugPrint("Background Tracking Service stopped by Admin signal.");
      }
    } catch (e) {
      debugPrint("Error stopping background service: $e");
    }
  }

  /// Centralized response processing logic
  ApiResponse _processResponse(http.Response response, {bool isAuth = false}) {
    dynamic body;
    try {
      body = json.decode(response.body);
    } catch (_) {
      body = response.body;
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      // Automatically unwrap the standard backend ResponseSchema { status, message, data }
      dynamic extractedData = body;
      if (body is Map && body.containsKey('data')) {
        extractedData = body['data'];
      }
      return ApiResponse(
        success: true,
        data: extractedData,
        message: 'Success',
      );
    }

    String? backendMessage;
    if (body is Map && body.containsKey('detail')) {
      backendMessage = body['detail'].toString();
    } else if (body is Map && body.containsKey('message')) {
      backendMessage = body['message'].toString();
    }

    switch (response.statusCode) {
      case 401:
        // ONLY force logout if this is NOT a login/auth attempt
        if (!isAuth) {
          _forceLogout();
          return ApiResponse(
            success: false,
            message: backendMessage ?? 'Session expired.',
          );
        }
        return ApiResponse(
          success: false,
          message: backendMessage ?? 'Invalid credentials.',
        );
      case 403:
        if (backendMessage == "JOURNEY_STOPPED_BY_ADMIN") {
          _stopBackgroundJourney();
          return ApiResponse(
            success: false,
            message: 'Journey stopped by administrator.',
          );
        }
        return ApiResponse(success: false, message: 'Permission denied.');
      case 404:
        return ApiResponse(success: false, message: 'Not found.');
      case 422:
        final errorResponse = json.decode(response.body);
        final String message =
            errorResponse['detail'] ??
            errorResponse['message'] ??
            'Unknown server error (${response.statusCode})';

        debugPrint('[API FAIL] Response: ${response.body}');
        return ApiResponse(success: false, message: message);
      case 500:
        debugPrint('[API FAIL] Response: ${response.body}');
        return ApiResponse(success: false, message: 'Server error.');
      default:
        try {
          debugPrint('[API FAIL] Response: ${response.body}');
          return ApiResponse(
            success: false,
            message: 'Error: ${response.statusCode}',
          );
        } catch (e) {
          debugPrint('[API FAIL] Could not parse error body: ${response.body}');
          return ApiResponse(
            success: false,
            message: 'Server error (${response.statusCode})',
          );
        }
    }
  }

  /// GET Request
  Future<ApiResponse> get(String endpoint, {bool isAuth = false}) async {
    final baseUrl = await _getValidBaseUrl();
    return _sendRequest(() async {
      final headers = await _getHeaders(isAuth: isAuth);
      return http.get(Uri.parse('$baseUrl$endpoint'), headers: headers);
    }, isAuth: isAuth);
  }

  /// POST Request
  Future<ApiResponse> post(
    String endpoint,
    dynamic body, {
    bool isAuth = false,
  }) async {
    final baseUrl = await _getValidBaseUrl();
    return _sendRequest(() async {
      final headers = await _getHeaders(isAuth: isAuth);
      return http.post(
        Uri.parse('$baseUrl$endpoint'),
        headers: headers,
        body: json.encode(body),
      );
    }, isAuth: isAuth);
  }

  /// POST Form-UrlEncoded Request
  Future<ApiResponse> postForm(
    String endpoint,
    Map<String, String> body, {
    bool isAuth = false,
  }) async {
    final baseUrl = await _getValidBaseUrl();
    return _sendRequest(() async {
      final headers = await _getHeaders(isAuth: isAuth);
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
      return http.post(
        Uri.parse('$baseUrl$endpoint'),
        headers: headers,
        body: body,
      );
    }, isAuth: isAuth);
  }

  /// PUT Request
  Future<ApiResponse> put(
    String endpoint,
    dynamic body, {
    bool isAuth = false,
  }) async {
    final baseUrl = await _getValidBaseUrl();
    return _sendRequest(() async {
      final headers = await _getHeaders(isAuth: isAuth);
      return http.put(
        Uri.parse('$baseUrl$endpoint'),
        headers: headers,
        body: json.encode(body),
      );
    }, isAuth: isAuth);
  }

  /// DELETE Request
  Future<ApiResponse> delete(String endpoint, {bool isAuth = false}) async {
    final baseUrl = await _getValidBaseUrl();
    return _sendRequest(() async {
      final headers = await _getHeaders(isAuth: isAuth);
      return http.delete(Uri.parse('$baseUrl$endpoint'), headers: headers);
    }, isAuth: isAuth);
  }
}
