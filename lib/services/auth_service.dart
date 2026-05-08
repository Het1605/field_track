import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';

class AuthService {
  final ApiService _apiService = ApiService();
  static const String _accessTokenKey = 'auth_token';
  static const String _refreshTokenKey = 'refresh_token';

  /// Calls the login API and stores the tokens if successful
  Future<ApiResponse> login(String email, String password) async {
    final response = await _apiService.postForm('/auth/login', {
      'username': email,
      'password': password,
    }, isAuth: true);

    if (response.success && response.data != null) {
      final String? accessToken = response.data['access_token'];
      final String? refreshToken = response.data['refresh_token'];
      
      if (accessToken != null) {
        await _saveTokens(accessToken, refreshToken);
      }
    }

    return response;
  }

  /// Attempts to refresh the access token using the stored refresh token
  Future<ApiResponse> refreshToken() async {
    final String? refreshToken = await getRefreshToken();
    if (refreshToken == null) {
      return ApiResponse(success: false, message: 'No refresh token available');
    }

    final response = await _apiService.post('/auth/refresh', {
      'refresh_token': refreshToken,
    }, isAuth: true);

    if (response.success && response.data != null) {
      final String? newAccess = response.data['access_token'];
      final String? newRefresh = response.data['refresh_token']; // Optional rotation
      
      if (newAccess != null) {
        await _saveTokens(newAccess, newRefresh ?? refreshToken);
      }
    }

    return response;
  }

  /// Saves tokens securely in shared_preferences
  Future<void> _saveTokens(String accessToken, String? refreshToken) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accessTokenKey, accessToken);
    if (refreshToken != null) {
      await prefs.setString(_refreshTokenKey, refreshToken);
    }
  }

  /// Retrieves the stored Access Token
  Future<String?> getToken() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getString(_accessTokenKey);
  }

  /// Retrieves the stored Refresh Token
  Future<String?> getRefreshToken() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getString(_refreshTokenKey);
  }

  /// Removes both tokens (Logout)
  Future<void> logout() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_accessTokenKey);
    await prefs.remove(_refreshTokenKey);
  }

  /// Check if the user is currently logged in
  Future<bool> isLoggedIn() async {
    final token = await getToken();
    return token != null && token.isNotEmpty;
  }

  /// Sends a password reset link
  Future<ApiResponse> forgotPassword(String email) async {
    return await _apiService.post('/auth/reset-password', {
      'email': email,
    }, isAuth: true);
  }
}
