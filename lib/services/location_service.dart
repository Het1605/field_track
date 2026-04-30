import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'api_service.dart';
import 'database_service.dart';

/// Service to handle real-time GPS tracking with offline storage and batch upload
class LocationTrackingService {
  final ApiService _apiService = ApiService();
  final DatabaseService _dbService = DatabaseService();
  Timer? _trackingTimer;
  
  // Tracking interval (3 minutes)
  static const Duration _interval = Duration(seconds: 20);

  /// Handles location permission requests (Foreground and Notifications)
  Future<bool> handlePermissions() async {
    // 1. Request Foreground Location
    PermissionStatus status = await Permission.location.status;
    if (status.isDenied) {
      status = await Permission.location.request();
    }
    
    if (status.isPermanentlyDenied || status.isDenied) {
      return false;
    }

    // 2. Request Notification Permission (Required for Background Service tray icon)
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }

    return status.isGranted;
  }

  /// Fetches the current GPS position
  Future<Position> getCurrentLocation() async {
    return await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
      ),
    );
  }

  /// Starts the tracking engine (Initial manual trigger)
  void startTracking({
    required String journeyId,
    required int companyId,
  }) {
    debugPrint('GPS Tracking Engine initialized.');
    
    // Perform one immediate manual track to ensure the journey starts with a point
    trackAndSave(journeyId, companyId);
    
    // NOTE: We no longer start a Timer here because the BackgroundService 
    // now handles the periodic 3-minute tracking logic exclusively.
  }

  /// Stops the tracking engine
  void stopTracking() {
    debugPrint('GPS Tracking Engine stopped.');
  }

  /// Fetches GPS, saves locally, and attempts batch sync (Public for Background Service)
  Future<void> trackAndSave(String journeyId, int companyId) async {
    try {
      // 1. Fetch current GPS position
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
        ),
      );

      // 2. SAVE LOCALLY (Ensure no data loss even if offline)
      await _dbService.saveLocation(
        journeyId: journeyId,
        latitude: position.latitude,
        longitude: position.longitude,
        recordedAt: DateTime.now().toUtc().toIso8601String(),
      );

      debugPrint('Location saved locally: ${position.latitude}, ${position.longitude}');

      // 3. ATTEMPT BATCH SYNC
      await sendStoredLocations(companyId);

    } catch (e) {
      debugPrint('Tracking/Offline Storage Error: $e');
    }
  }

  /// Fetches all unsent locations and sends them in a single batch to the backend
  Future<void> sendStoredLocations(int companyId) async {
    try {
      // 0. Clean up any records with invalid IDs first
      await _dbService.deleteCorruptedRecords();

      // 1. Fetch all unsent locations from SQLite
      final List<Map<String, dynamic>> storedPoints = await _dbService.getAllStoredLocations();
      if (storedPoints.isEmpty) {
        debugPrint('No points to sync.');
        return;
      }

      // 2. Group points by journey_id (in case of multiple abandoned journeys)
      final Map<String, List<Map<String, dynamic>>> groupedByJourney = {};
      for (var point in storedPoints) {
        final rawId = point['journey_id'];
        if (rawId == null || rawId == 'null') continue; // Skip corrupted/invalid records
        
        final jId = rawId.toString();
        groupedByJourney.putIfAbsent(jId, () => []).add(point);
      }

      // 3. Process each journey's points in a single batch request
      for (var journeyId in groupedByJourney.keys) {
        final points = groupedByJourney[journeyId]!;
        
        final trackPayload = {
          'journey_id': journeyId,
          'company_id': companyId,
          'locations': points.map((p) => {
            'latitude': p['latitude'],
            'longitude': p['longitude'],
            'recorded_at': p['recorded_at'],
          }).toList()
        };

        debugPrint('Attempting batch sync for $journeyId (${points.length} points)...');

        final response = await _apiService.post('/location/track', trackPayload);
        
        if (response.success) {
          // 4. DELETE successful records to prevent double-sync
          final List<int> syncedIds = points.map((p) => p['id'] as int).toList();
          await _dbService.deleteSyncedRecords(syncedIds);
          debugPrint('Successfully synced and cleared ${points.length} points for journey $journeyId');
        } else {
          debugPrint('Sync failed for $journeyId: ${response.message}. Data kept in local DB.');
        }
      }
    } catch (e) {
      debugPrint('Critical Batch Sync Error: $e');
    }
  }
}
