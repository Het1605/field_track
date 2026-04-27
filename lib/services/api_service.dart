import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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
  // Base URL Configuration
  // Android Emulator: http://10.0.2.2:8000/api
  // iOS Emulator/Real Device: http://<your-local-ip>:8000/api
  static const String _baseUrl = 'http://10.0.2.2:8000/api';
  
  // Timeout duration
  static const Duration _timeout = Duration(seconds: 15);

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

  /// Reusable request handler with centralized error handling
  Future<ApiResponse> _sendRequest(
    Future<http.Response> Function() request,
  ) async {
    try {
      final response = await request().timeout(_timeout);
      return _processResponse(response);
    } on SocketException {
      return ApiResponse(
        success: false, 
        message: 'No internet connection. Please check your network.',
      );
    } on TimeoutException {
      return ApiResponse(
        success: false, 
        message: 'Request timed out. The server is taking too long to respond.',
      );
    } on http.ClientException catch (e) {
      return ApiResponse(
        success: false, 
        message: 'Network failure: ${e.message}',
      );
    } catch (e) {
      return ApiResponse(
        success: false, 
        message: 'An unexpected error occurred: ${e.toString()}',
      );
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
      return ApiResponse(
        success: true,
        data: body,
        message: 'Success',
      );
    }

    // Handle Specific Error Status Codes
    switch (response.statusCode) {
      case 401:
        return ApiResponse(
          success: false,
          message: 'Unauthorized: Session expired or invalid token.',
        );
      case 403:
        return ApiResponse(
          success: false,
          message: 'Forbidden: You do not have permission to access this resource.',
        );
      case 404:
        return ApiResponse(
          success: false,
          message: 'Resource not found.',
        );
      case 500:
        return ApiResponse(
          success: false,
          message: 'Internal Server Error. Please try again later.',
        );
      default:
        // Try to extract error message from backend if available
        String errorMsg = 'Error ${response.statusCode}';
        if (body is Map && body.containsKey('detail')) {
          errorMsg = body['detail'].toString();
        } else if (body is Map && body.containsKey('message')) {
          errorMsg = body['message'].toString();
        }
        
        return ApiResponse(
          success: false,
          data: body,
          message: errorMsg,
        );
    }
  }

  /// GET Request
  Future<ApiResponse> get(String endpoint) async {
    final headers = await _getHeaders();
    return _sendRequest(() => http.get(
      Uri.parse('$_baseUrl$endpoint'),
      headers: headers,
    ));
  }

  /// POST Request
  Future<ApiResponse> post(String endpoint, dynamic body) async {
    final headers = await _getHeaders();
    return _sendRequest(() => http.post(
      Uri.parse('$_baseUrl$endpoint'),
      headers: headers,
      body: json.encode(body),
    ));
  }

  /// PUT Request
  Future<ApiResponse> put(String endpoint, dynamic body) async {
    final headers = await _getHeaders();
    return _sendRequest(() => http.put(
      Uri.parse('$_baseUrl$endpoint'),
      headers: headers,
      body: json.encode(body),
    ));
  }

  /// DELETE Request
  Future<ApiResponse> delete(String endpoint) async {
    final headers = await _getHeaders();
    return _sendRequest(() => http.delete(
      Uri.parse('$_baseUrl$endpoint'),
      headers: headers,
    ));
  }
}
