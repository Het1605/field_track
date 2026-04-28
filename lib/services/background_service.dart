import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/location_service.dart';

/// Phase 4 & 5: Local Storage & API Sync Integration
/// This class manages the lifecycle of the Android Foreground Service and GPS tracking.
class BackgroundServiceManager {
  static const String notificationChannelId = 'field_track_tracking_channel';

  /// Initializes the service configuration
  static Future<void> initializeService() async {
    final service = FlutterBackgroundService();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: notificationChannelId,
        initialNotificationTitle: 'Field Track: Active',
        initialNotificationContent: 'GPS Tracking Initializing...',
        foregroundServiceTypes: [AndroidForegroundType.location],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );
  }

  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    return true;
  }

  /// The entry point for the background isolate
  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    // Ensure the background isolate is correctly bound to Flutter
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();

    final LocationTrackingService trackingService = LocationTrackingService();

    if (service is AndroidServiceInstance) {
      service.on('setAsForeground').listen((event) {
        service.setAsForegroundService();
      });

      service.on('setAsBackground').listen((event) {
        service.setAsBackgroundService();
      });
    }

    service.on('stopService').listen((event) {
      service.stopSelf();
    });

    // Phase 4 & 5: GPS Tracking + DB Save + API Sync
    // Run every 3 minutes
    Timer.periodic(const Duration(minutes: 3), (timer) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload(); // Critical: Reload to see data from main isolate

        final String? journeyId = prefs.getString('active_journey_id');
        final int? companyId = prefs.getInt('selected_company_id');

        if (journeyId != null && companyId != null) {
          // Trigger the full tracking logic (GPS -> SQLite -> API)
          await trackingService.trackAndSave(journeyId, companyId);

          // Update Notification with Status
          if (service is AndroidServiceInstance) {
            if (await service.isForegroundService()) {
              service.setForegroundNotificationInfo(
                title: "Field Track: Tracking Active",
                content: "Data synced successfully at ${DateTime.now().toLocal().toString().split('.')[0]}",
              );
            }
          }
        } else {
          debugPrint('Background Isolate: No active journey found in prefs.');
        }
      } catch (e) {
        debugPrint('Background Sync Loop Error: $e');
      }
    });
  }
}
