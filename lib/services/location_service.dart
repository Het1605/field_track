import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';
import 'database_service.dart';

/// Service to handle real-time GPS tracking with offline storage and batch upload
class LocationTrackingService {
  final ApiService _apiService;
  final DatabaseService _dbService = DatabaseService();
  final bool isBackground;
  Timer? _trackingTimer;
  bool _isSyncing = false;

  LocationTrackingService({this.isBackground = false})
    : _apiService = ApiService(isBackground: isBackground);

  /// Ensures that ApiService and DatabaseService are initialized before use
  Future<void> waitForInit() async {
    // Wait for ApiService to load its base URL
    int attempts = 0;
    while (_apiService.baseUrl.isEmpty && attempts < 10) {
      await Future.delayed(const Duration(milliseconds: 500));
      attempts++;
    }
    // DatabaseService initializes itself on the first get database call
  }

  // Tracking interval (3 minutes)
  static const Duration _interval = Duration(minutes: 1);

  /// Handles location permission requests (Foreground and Notifications)
  Future<bool> handlePermissions() async {
    // 1. Check Foreground Location Status
    PermissionStatus status = await Permission.location.status;

    if (status.isPermanentlyDenied) {
      // If permanently denied, take them to settings so they can enable it manually
      await openAppSettings();
      return false;
    }

    if (status.isDenied) {
      // If denied (first time or second time), request it again
      status = await Permission.location.request();
      if (status.isPermanentlyDenied) {
        await openAppSettings();
        return false;
      }
    }

    if (!status.isGranted) {
      return false;
    }

    // 2. Request Background Location (Required for Android 10+ and iOS background tracking)
    // On Android 11+, this must be requested AFTER foreground permission is granted.
    PermissionStatus alwaysStatus = await Permission.locationAlways.status;
    if (alwaysStatus.isDenied) {
      alwaysStatus = await Permission.locationAlways.request();
    }

    // 3. Request Notification Permission (Required for Background Service tray icon)
    PermissionStatus notificationStatus = await Permission.notification.status;
    if (notificationStatus.isDenied) {
      await Permission.notification.request();
    }

    return status.isGranted && alwaysStatus.isGranted;
  }

  /// Fetches the current GPS position
  Future<Position> getCurrentLocation() async {
    return await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
  }

  /// Starts the tracking engine (Initial manual trigger)
  void startTracking({required String journeyId, required int companyId}) {
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
    if (journeyId == "null" || journeyId.isEmpty) {
      debugPrint('GPS: Refusing to save location for invalid Journey ID.');
      return;
    }
    try {
      // 1. Fetch current GPS position
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
        ),
      ).timeout(const Duration(seconds: 25));

      // 2. SAVE LOCALLY (Ensure no data loss even if offline)
      await _dbService.saveLocation(
        journeyId: journeyId,
        latitude: position.latitude,
        longitude: position.longitude,
        recordedAt: DateTime.now().toUtc().toIso8601String(),
      );

      debugPrint(
        'Location saved locally: ${position.latitude}, ${position.longitude}',
      );

      // 3. ATTEMPT BATCH SYNC
      await sendStoredLocations(companyId);
      await _updateCacheCount();
    } catch (e) {
      debugPrint('Tracking/Offline Storage Error: $e');
    }
  }

  /// Updates the SharedPreferences with the current number of unsent points
  Future<void> _updateCacheCount() async {
    final List<Map<String, dynamic>> points = await _dbService.getAllStoredLocations();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('cached_points_count', points.length);
  }

  /// Retrieves all stored locations and attempts to sync them in small chunks
  Future<void> sendStoredLocations(int companyId) async {
    if (_isSyncing) return;
    _isSyncing = true;

    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final String? journeyId = prefs.getString('active_journey_id');

      // 1. Fetch all unsent locations from SQLite
      final List<Map<String, dynamic>> storedPoints =
          await _dbService.getAllStoredLocations();
      if (storedPoints.isEmpty) {
        _isSyncing = false;
        return;
      }

      // 2. Group points by journey_id
      final Map<String, List<Map<String, dynamic>>> groupedByJourney = {};
      for (var point in storedPoints) {
        final rawId = point['journey_id'];
        if (rawId == null || rawId == 'null') continue;
        groupedByJourney.putIfAbsent(rawId.toString(), () => []).add(point);
      }

      // 3. Process each journey
      for (var jId in groupedByJourney.keys) {
        final List<Map<String, dynamic>> allPoints = groupedByJourney[jId]!;

        // CHUNKING: Split allPoints into groups of 20
        const int chunkSize = 20;
        for (int i = 0; i < allPoints.length; i += chunkSize) {
          final int end = (i + chunkSize < allPoints.length)
              ? i + chunkSize
              : allPoints.length;
          final List<Map<String, dynamic>> chunk = allPoints.sublist(i, end);

          final trackPayload = {
            'journey_id': jId,
            'company_id': companyId,
            'locations':
                chunk
                    .map(
                      (p) => {
                        'latitude': p['latitude'],
                        'longitude': p['longitude'],
                        'recorded_at': p['recorded_at'],
                      },
                    )
                    .toList(),
          };

          debugPrint(
            '[Sync] Sending chunk for $jId (${chunk.length} points, ${i + chunk.length}/${allPoints.length})...',
          );

          final response = await _apiService.post('/location/track', trackPayload);

          if (response.success) {
            final List<int> syncedIds = chunk.map((p) => p['id'] as int).toList();
            await _dbService.deleteSyncedRecords(syncedIds);
          } else {
            // IF FAILURE: Stop the loop for this journey immediately. 
            // We don't want to keep hitting a dead network.
            debugPrint('[Sync] Chunk failed: ${response.message}. Stopping loop.');
            break; 
          }
        }
      }
      await _updateCacheCount();
    } catch (e) {
      debugPrint('Critical Batch Sync Error: $e');
    } finally {
      _isSyncing = false;
    }
  }
}
