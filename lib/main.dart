import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/background_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Load Environment Variables (.env)
  await dotenv.load(fileName: ".env");

  // 2. Persist BASE_URL for background isolate access
  final prefs = await SharedPreferences.getInstance();
  final String? baseUrl = dotenv.env['BASE_URL'];
  if (baseUrl != null) {
    await prefs.setString('api_base_url', baseUrl);
  }

  // 3. Initialize Background Service
  await BackgroundServiceManager.initializeService();

  // 3. Determine Initial Route (Auto-Login)
  final String? token = prefs.getString('auth_token');
  final bool hasActiveJourney = prefs.getString('active_journey_id') != null;

  runApp(FieldTrackApp(
    initialHome: (token != null || hasActiveJourney)
        ? const HomeScreen()
        : const LoginScreen(),
  ));
}

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class FieldTrackApp extends StatelessWidget {
  final Widget initialHome;
  const FieldTrackApp({super.key, required this.initialHome});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Field Track',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          filled: true,
          fillColor: Color(0xFFF5F5F5),
        ),
      ),
      home: initialHome,
    );
  }
}
