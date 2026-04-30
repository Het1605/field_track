import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Standardized Response Object for all API calls
class ApiResponse {
  final bool success;
  final dynamic data;
  final String message;

  ApiResponse({
    required this.success,
    this.data,
    required this.message,
  });

  @override
  String toString() => 'ApiResponse(success: $success, message: $message, data: $data)';
}

/// Centralized API Service Layer for Field Track
class ApiService {
  // Base URL Configuration (Strictly loaded from .env)
  final String _baseUrl = dotenv.env['BASE_URL']!;
  
  // Timeout duration
  static const Duration _timeout = Duration(seconds: 15);

  // Prevent multiple concurrent refreshes
  bool _isRefreshing = false;

  /// Private method to get common headers with JWT authentication
  Future<Map<String, String>> _getHeaders() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('auth_token');

    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  /// Reusable request handler with centralized error handling and retry logic
  Future<ApiResponse> _sendRequest(
    Future<http.Response> Function() request, {
    bool canRetry = true,
  }) async {
    try {
      final response = await request().timeout(_timeout);
      
      // Handle 401 Unauthorized specifically for retry logic
      if (response.statusCode == 401 && canRetry) {
        final refreshSuccess = await _attemptTokenRefresh();
        if (refreshSuccess) {
          // Retry original request exactly once with new headers
          return await _sendRequest(request, canRetry: false);
        }
      }

      return _processResponse(response);
    } on SocketException {
      return ApiResponse(success: false, message: 'No internet connection.');
    } on TimeoutException {
      return ApiResponse(success: false, message: 'Request timed out.');
    } catch (e) {
      return ApiResponse(success: false, message: 'Connection error: ${e.toString()}');
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

      final response = await http.post(
        Uri.parse('$_baseUrl/auth/refresh'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'refresh_token': refreshToken}),
      ).timeout(_timeout);

      if (response.statusCode == 200) {
        final body = json.decode(response.body);
        final String? newAccess = body['access_token'];
        final String? newRefresh = body['refresh_token'];

        if (newAccess != null) {
          await prefs.setString('auth_token', newAccess);
          if (newRefresh != null) {
            await prefs.setString('refresh_token', newRefresh);
          }
          return true;
        }
      }
      return false;
    } catch (e) {
      return false;
    } finally {
      _isRefreshing = false;
    }
  }

  /// Centralized response processing logic
  ApiResponse _processResponse(http.Response response) {
    dynamic body;
    try {
      body = json.decode(response.body);
    } catch (_) {
      body = response.body;
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return ApiResponse(success: true, data: body, message: 'Success');
    }

    String? backendMessage;
    if (body is Map && body.containsKey('detail')) {
      backendMessage = body['detail'].toString();
    } else if (body is Map && body.containsKey('message')) {
      backendMessage = body['message'].toString();
    }

    switch (response.statusCode) {
      case 401:
        return ApiResponse(success: false, message: backendMessage ?? 'Session expired.');
      case 403:
        return ApiResponse(success: false, message: 'Permission denied.');
      case 404:
        return ApiResponse(success: false, message: 'Not found.');
      case 422:
        return ApiResponse(success: false, message: backendMessage ?? 'Validation error.', data: body);
      case 500:
        return ApiResponse(success: false, message: 'Server error.');
      default:
        return ApiResponse(success: false, message: 'Error: ${response.statusCode}');
    }
  }

  /// GET Request
  Future<ApiResponse> get(String endpoint) async {
    return _sendRequest(() async {
      final headers = await _getHeaders();
      return http.get(Uri.parse('$_baseUrl$endpoint'), headers: headers);
    });
  }

  /// POST Request
  Future<ApiResponse> post(String endpoint, dynamic body) async {
    return _sendRequest(() async {
      final headers = await _getHeaders();
      return http.post(
        Uri.parse('$_baseUrl$endpoint'),
        headers: headers,
        body: json.encode(body),
      );
    });
  }

  /// POST Form-UrlEncoded Request
  Future<ApiResponse> postForm(String endpoint, Map<String, String> body) async {
    return _sendRequest(() async {
      final headers = await _getHeaders();
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
      return http.post(Uri.parse('$_baseUrl$endpoint'), headers: headers, body: body);
    });
  }

  /// PUT Request
  Future<ApiResponse> put(String endpoint, dynamic body) async {
    return _sendRequest(() async {
      final headers = await _getHeaders();
      return http.put(
        Uri.parse('$_baseUrl$endpoint'),
        headers: headers,
        body: json.encode(body),
      );
    });
  }

  /// DELETE Request
  Future<ApiResponse> delete(String endpoint) async {
    return _sendRequest(() async {
      final headers = await _getHeaders();
      return http.delete(Uri.parse('$_baseUrl$endpoint'), headers: headers);
    });
  }
}
