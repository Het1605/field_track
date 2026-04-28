import 'package:flutter/material.dart';
import 'services/background_service.dart';
import 'screens/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize Background Service (Phase 1)
  await BackgroundServiceManager.initializeService();
  
  runApp(const FieldTrackApp());
}

class FieldTrackApp extends StatelessWidget {
  const FieldTrackApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
      // Initial screen is the Login Screen
      home: const LoginScreen(),
    );
  }
}
