import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'api_service.dart';

/// Service to handle real-time GPS tracking and API synchronization
class LocationTrackingService {
  final ApiService _apiService = ApiService();
  Timer? _trackingTimer;
  
  // Tracking interval as per requirements (3 minutes)
  static const Duration _interval = Duration(minutes: 3);

  /// Handles location permission requests and returns true if granted
  Future<bool> handlePermissions() async {
    PermissionStatus status = await Permission.location.status;
    
    if (status.isDenied) {
      status = await Permission.location.request();
    }
    
    if (status.isPermanentlyDenied) {
      // Opens app settings so user can manually enable permission
      await openAppSettings();
      return false;
    }
    
    return status.isGranted;
  }

  /// Starts the periodic tracking engine
  void startTracking({
    required String journeyId,
    required int companyId,
  }) {
    // Prevent multiple timers
    stopTracking();
    
    debugPrint('GPS Tracking started for journey: $journeyId');
    
    // Initial tracking immediately
    _trackAndSync(journeyId, companyId);
    
    // Set up periodic sync
    _trackingTimer = Timer.periodic(_interval, (_) {
      _trackAndSync(journeyId, companyId);
    });
  }

  /// Stops the tracking engine and cancels the timer
  void stopTracking() {
    if (_trackingTimer != null) {
      _trackingTimer!.cancel();
      _trackingTimer = null;
      debugPrint('GPS Tracking stopped.');
    }
  }

  /// Internal method to fetch GPS and push to backend
  Future<void> _trackAndSync(String journeyId, int companyId) async {
    try {
      // 1. Fetch current GPS position
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
        ),
      );

      // 2. Prepare payload (matching backend schema)
      final trackData = {
        'journey_id': journeyId,
        'company_id': companyId,
        'locations': [
          {
            'latitude': position.latitude,
            'longitude': position.longitude,
            'recorded_at': DateTime.now().toUtc().toIso8601String(),
          }
        ]
      };

      // 3. Sync with backend
      final response = await _apiService.post('/location/track', trackData);
      
      if (!response.success) {
        debugPrint('Sync Error: ${response.message}');
      } else {
        debugPrint('Location synced successfully: ${position.latitude}, ${position.longitude}');
      }
    } catch (e) {
      debugPrint('Tracking Error: $e');
    }
  }
}
