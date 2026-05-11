import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/location_service.dart';
import 'api_service.dart';

/// Top-level function for IOS Background execution (Must be top-level for AOT)
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

/// Top-level entry point for the background isolate (Must be top-level for AOT)
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: ".env");
  } catch (_) {}
  DartPluginRegistrant.ensureInitialized();

  // 1. Initialize for Background
  final trackingService = LocationTrackingService(isBackground: true);
  
  // 2. Wait for API/Database readiness
  await trackingService.waitForInit();
  debugPrint('[BackgroundService] Engine ready.');

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  // Phase 4 & 5: GPS Tracking + DB Save + API Sync
  Timer.periodic(const Duration(minutes: 1), (timer) async {
    debugPrint('[BackgroundService] Heartbeat: Service is alive.');
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      // DEBUG: Increment heartbeat counter
      final int currentTicks = prefs.getInt('background_tick_count') ?? 0;
      await prefs.setInt('background_tick_count', currentTicks + 1);

      final String? journeyId = prefs.getString('active_journey_id');
      final int? companyId = prefs.getInt('selected_company_id');

      if (journeyId != null && journeyId != "null" && companyId != null) {
        debugPrint('[BackgroundService] Processing tracking for $journeyId');
        await trackingService.trackAndSave(journeyId, companyId);
      } else {
        debugPrint('[BackgroundService] Sleeping: No active journey in memory.');
      }
    } catch (e) {
      debugPrint('[BackgroundService] Timer Error: $e');
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
