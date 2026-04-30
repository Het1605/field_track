import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../services/location_service.dart';

/// Top-level function for IOS Background execution (Must be top-level for AOT)
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

/// Top-level entry point for the background isolate (Must be top-level for AOT)
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  // Ensure the background isolate is correctly bound to Flutter
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  LocationTrackingService? trackingService;

  try {
    // CRITICAL: Load environment variables for this specific isolate
    await dotenv.load();
    trackingService = LocationTrackingService();
    debugPrint('[BackgroundService] Successfully initialized Tracking Service.');
  } catch (e) {
    debugPrint('[BackgroundService] CRITICAL INITIALIZATION ERROR: $e');
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  // Phase 4 & 5: GPS Tracking + DB Save + API Sync
  Timer.periodic(const Duration(minutes: 3), (timer) async {
    if (trackingService == null) {
      debugPrint('[BackgroundService] Skipping tick: trackingService not initialized.');
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      final String? journeyId = prefs.getString('active_journey_id');
      final int? companyId = prefs.getInt('selected_company_id');

      if (journeyId != null && companyId != null) {
        // Trigger the full tracking logic (GPS -> SQLite -> API)
        await trackingService.trackAndSave(journeyId, companyId);
      }
    } catch (e) {
      debugPrint('Background Sync Loop Error: $e');
    }
  });
}

/// Manager class for UI-side interaction
class BackgroundServiceManager {
  /// Initializes the service configuration
  static Future<void> initializeService() async {
    final service = FlutterBackgroundService();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        isForegroundMode: true,
        // Using default channel and standard settings for maximum stability
        initialNotificationTitle: 'Field Track: Active',
        initialNotificationContent: 'Monitoring your journey...',
        foregroundServiceTypes: [AndroidForegroundType.location],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );
  }
}
