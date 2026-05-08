import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart'; // Added for Position type
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/location_service.dart';
import 'change_password_screen.dart'; // New Import
import 'profile_screen.dart';
import 'login_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ApiService _apiService = ApiService();
  final AuthService _authService = AuthService();
  final LocationTrackingService _locationService = LocationTrackingService();

  bool _isLoading = false;
  bool _isInitializing = true;
  bool _isSessionValid = true;
  String? _activeJourneyId;
  String? _startTime;

  // Multi-company data
  List<dynamic> _companies = [];
  int? _selectedCompanyId;

  @override
  void initState() {
    super.initState();
    _initializeData();
  }

  @override
  void dispose() {
    _locationService.stopTracking();
    super.dispose();
  }

  /// Initial data load: Companies and Active Journey
  Future<void> _initializeData() async {
    setState(() {
      _isInitializing = true;
      _isSessionValid = true;
    });

    // 1. Fetch companies
    await _fetchUserCompanies();

    // 2. Check for active journey (Local + Backend Sync)
    await _syncActiveJourney();

    setState(() => _isInitializing = false);
  }

  /// Fetch companies assigned to the current user
  Future<void> _fetchUserCompanies() async {
    try {
      final response = await _apiService.get('/companies/my');
      if (response.success && response.data is List) {
        setState(() {
          _companies = response.data;
          _restoreOrAutoSelectCompany();
        });
      } else if (response.message.contains('Session expired')) {
        setState(() => _isSessionValid = false);
      }
    } catch (e) {
      debugPrint("Error fetching companies: $e");
    }
  }

  Future<void> _restoreOrAutoSelectCompany() async {
    final prefs = await SharedPreferences.getInstance();
    final savedCompanyId = prefs.getInt('selected_company_id');

    if (_companies.length == 1) {
      _selectedCompanyId = _companies.first['id'];
    } else if (savedCompanyId != null &&
        _companies.any((c) => c['id'] == savedCompanyId)) {
      _selectedCompanyId = savedCompanyId;
    } else if (_companies.isNotEmpty) {
      _selectedCompanyId = _companies.first['id'];
    }
  }

  /// Syncs the active journey state from backend and local storage
  Future<void> _syncActiveJourney() async {
    try {
      final response = await _apiService.get('/location/active-journey');
      final prefs = await SharedPreferences.getInstance();

      debugPrint("[Sync] Backend Response Data: ${response.data}");

      if (response.success && response.data != null) {
        // Backend says there is an active journey
        final dynamic journeyData = response.data;
        final String journeyId = journeyData['id'].toString();
        final int? companyId = journeyData['company_id'];
        final String? startTime = journeyData['start_time'];

        debugPrint("[Sync] Active Journey Found: $journeyId for Company: $companyId");

        if (companyId == null) {
           debugPrint("[Sync] Error: company_id is null");
           return;
        }

        // Format start time for UI
        String formattedStart = "Unknown";
        if (startTime != null) {
          try {
            final dt = DateTime.parse(startTime).toLocal();
            formattedStart = "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
          } catch (_) {}
        }

        // Sync local storage
        await prefs.setString('active_journey_id', journeyId);
        await prefs.setInt('selected_company_id', companyId);
        
        setState(() {
          _activeJourneyId = journeyId;
          _selectedCompanyId = companyId;
          _startTime = formattedStart;
        });
      } else {
        // No active journey on backend -> Clear local journey state ONLY
        // We do NOT clear _selectedCompanyId here because the user needs it to start a new trip!
        await prefs.remove('active_journey_id');
        await prefs.remove('journey_start_time');
        setState(() {
          _activeJourneyId = null;
          _startTime = null;
        });
      }
    } catch (e) {
      debugPrint("Error syncing active journey: $e");
    }
  }

  /// Shows a dialog to the user when a journey is found on app start
  void _showResumeJourneyDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.history_rounded, color: Colors.blue),
            SizedBox(width: 12),
            Text('Active Journey Found'),
          ],
        ),
        content: Text(
          'A journey started at $_startTime was found in progress. Would you like to resume tracking or end it now?',
          softWrap: true,
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _endJourney();
            },
            child: const Text('End Journey', style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              _resumeTracking();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green.shade600,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Resume Journey'),
          ),
        ],
      ),
    );
  }

  /// Resumes the tracking logic
  Future<void> _resumeTracking() async {
    if (_activeJourneyId == null || _selectedCompanyId == null) return;

    // Restart GPS Engine
    _locationService.startTracking(
      journeyId: _activeJourneyId!,
      companyId: _selectedCompanyId!,
    );

    // Restart Background Service
    try {
      await FlutterBackgroundService().startService();
    } catch (e) {
      debugPrint("Service start failed: $e");
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tracking resumed successfully'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _onCompanyChanged(int? newId) async {
    if (newId == null || isTracking) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('selected_company_id', newId);
    setState(() => _selectedCompanyId = newId);
  }

  bool get isTracking => _activeJourneyId != null;

  /// Starts a new journey and launches the Background Foreground Service
  Future<void> _startJourney() async {
    if (_selectedCompanyId == null) return;

    // 1. Check Permissions First
    final bool hasPermission = await _locationService.handlePermissions();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Location permission is required to track journeys.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    setState(() => _isLoading = true);
    try {
      // 2. Fetch current location for Start API
      final Position position = await _locationService.getCurrentLocation();

      // 3. Call Start API
      final response = await _apiService.post('/location/start', {
        'company_id': _selectedCompanyId,
        'start_lat': position.latitude,
        'start_lng': position.longitude,
      });

      if (response.success && response.data != null) {
        final dynamic journeyData = response.data;
        final String journeyId = journeyData['id'].toString();

        final prefs = await SharedPreferences.getInstance();
        final now = DateTime.now();
        final startTimeStr =
            "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";

        await prefs.setString('active_journey_id', journeyId);
        await prefs.setString('journey_start_time', startTimeStr);
        await prefs.setInt('selected_company_id', _selectedCompanyId!);

        // 3. Start Real-time GPS Tracking Engine
        _locationService.startTracking(
          journeyId: journeyId,
          companyId: _selectedCompanyId!,
        );

        // 4. Request Notification Permission (Critical for Android 13+ foreground service)
        if (await Permission.notification.isDenied) {
          await Permission.notification.request();
        }

        // 5. Start Background Foreground Service (Phase 1)
        // Increased delay to ensure the OS stabilizes after permission popups
        await Future.delayed(const Duration(milliseconds: 800));

        try {
          await FlutterBackgroundService().startService();
        } catch (e) {
          debugPrint("Service start failed: $e");
        }

        setState(() {
          _activeJourneyId = journeyId;
          _startTime = startTimeStr;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Journey started with background tracking'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(response.message),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to start journey'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Ends the journey and stops the background service
  Future<void> _endJourney() async {
    final prefs = await SharedPreferences.getInstance();
    
    // 1. Double-check IDs (Check memory first, then fallback to SharedPreferences)
    String? jId = _activeJourneyId;
    if (jId == null || jId == "null") {
      jId = prefs.getString('active_journey_id');
    }

    int? cId = _selectedCompanyId;
    if (cId == null) {
      cId = prefs.getInt('selected_company_id');
    }

    // If still null, the session is truly lost. Force reset UI.
    if (jId == null || jId == "null" || cId == null) {
      debugPrint("[End] Critical Error: Journey ID or Company ID missing. Force resetting state.");
      await _forceResetLocalState();
      return;
    }

    setState(() => _isLoading = true);
    try {
      // 1. Fetch current location for End API (With safety fallback)
      double lat = 0.0;
      double lng = 0.0;
      try {
        final Position position = await _locationService.getCurrentLocation();
        lat = position.latitude;
        lng = position.longitude;
      } catch (e) {
        debugPrint("Could not get final location for end journey: $e");
        // We continue with 0.0 so the user isn't stuck forever
      }

      // 2. Stop GPS Tracking Engine and Background Service (Phase 1)
      _locationService.stopTracking();
      FlutterBackgroundService().invoke("stopService");

      // 3. Call End API
      final response = await _apiService.post('/location/end', {
        'journey_id': jId,
        'company_id': cId,
        'end_lat': lat,
        'end_lng': lng,
      });

      if (response.success || response.message.contains("404") || response.message.contains("not found")) {
        // If success OR if the journey was already ended on the server (404)
        await _forceResetLocalState();
        
        if (mounted && response.success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Journey and tracking stopped'),
              backgroundColor: Colors.blue,
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(response.message),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to end journey: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Force clears all local journey tracking data to fix stuck UI
  Future<void> _forceResetLocalState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('active_journey_id');
    await prefs.remove('journey_start_time');
    
    // Stop background tasks
    _locationService.stopTracking();
    FlutterBackgroundService().invoke("stopService");

    setState(() {
      _activeJourneyId = null;
      _startTime = null;
    });
  }

  void _handleLogout() async {
    if (isTracking) {
      _showActiveJourneyLogoutDialog();
    } else {
      _performLogout();
    }
  }

  /// Shows a professional dialog warning the user about an active journey
  void _showActiveJourneyLogoutDialog() {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.orange),
                SizedBox(width: 8),
                Expanded(child: Text('Active Journey Running', softWrap: true)),
              ],
            ),
            content: const SingleChildScrollView(
              child: Text(
                'You must end your journey before logging out to ensure your records are saved correctly.',
                softWrap: true,
              ),
            ),
            actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            actionsAlignment: MainAxisAlignment.end,
            actionsOverflowButtonSpacing: 8,
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
              ElevatedButton(
                onPressed: () async {
                  Navigator.pop(context); // Close dialog
                  await _endJourney(); // End journey first
                  _performLogout(); // Then logout
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade600,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                child: const Text(
                  'End Journey & Logout',
                  textAlign: TextAlign.center,
                  softWrap: true,
                ),
              ),
            ],
          ),
    );
  }

  /// Core logout logic shared between direct and intercepted logout
  void _performLogout() async {
    _locationService.stopTracking(); // Stop tracking immediately
    FlutterBackgroundService().invoke(
      "stopService",
    ); // Stop background service (Phase 1)

    // Clear journey session data
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('active_journey_id');
    await prefs.remove('journey_start_time');

    // Clear Auth token via service
    await _authService.logout();

    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitializing) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final size = MediaQuery.of(context).size;
    final isLargeScreen = size.width > 600;

    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      appBar: AppBar(
        title: const Text(
          'Journey Control',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'my_profile') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ProfileScreen(),
                  ),
                );
              } else if (value == 'change_password') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ChangePasswordScreen(),
                  ),
                );
              } else if (value == 'logout') {
                _handleLogout();
              }
            },
            offset: const Offset(0, 50),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            itemBuilder:
                (context) => [
                  const PopupMenuItem(
                    value: 'my_profile',
                    child: Row(
                      children: [
                        Icon(Icons.person_outline_rounded, color: Colors.blue),
                        SizedBox(width: 12),
                        Text('My Profile'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'change_password',
                    child: Row(
                      children: [
                        Icon(Icons.lock_reset_rounded, color: Colors.blueGrey),
                        SizedBox(width: 12),
                        Text('Change Password'),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'logout',
                    child: Row(
                      children: [
                        Icon(Icons.logout_rounded, color: Colors.redAccent),
                        SizedBox(width: 12),
                        Text(
                          'Logout',
                          style: TextStyle(color: Colors.redAccent),
                        ),
                      ],
                    ),
                  ),
                ],
            child: const Padding(
              padding: EdgeInsets.only(right: 16.0),
              child: CircleAvatar(
                radius: 18,
                backgroundColor: Color(0xFFE2E8F0),
                child: Icon(
                  Icons.person_outline_rounded,
                  color: Color(0xFF475569),
                  size: 20,
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (!_isSessionValid) _buildSessionWarningBanner(),
            Expanded(
              child: _companies.isEmpty
                  ? _buildNoCompanyState()
                  : _buildTrackingContent(size, isLargeScreen),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoCompanyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.orange.withAlpha(20),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.domain_disabled,
                size: 64,
                color: Colors.orange,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'No Company Assigned',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1E293B),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'You are not assigned to any company yet. Please contact your administrator to get started.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                color: Color(0xFF64748B),
                height: 1.5,
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _isLoading ? null : _initializeData,
              icon: _isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
              label: const Text('Refresh Status'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrackingContent(Size size, bool isLargeScreen) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: isLargeScreen ? size.width * 0.2 : 24.0,
          vertical: size.height * 0.05,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (_companies.length > 1) ...[
              _buildCompanySelector(),
              SizedBox(height: size.height * 0.05),
            ],
            _buildStatusVisualizer(size),
            SizedBox(height: size.height * 0.05),
            Text(
              isTracking ? 'Tracking in Progress' : 'Not Tracking',
              style: TextStyle(
                fontSize: isLargeScreen ? 32 : 26,
                fontWeight: FontWeight.w800,
                color: isTracking
                    ? Colors.green.shade700
                    : Colors.blueGrey.shade700,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 12),
            if (isTracking && _startTime != null) _buildStartTimeBadge(),
            SizedBox(height: size.height * 0.1),
            _buildMainActionButton(),
            const SizedBox(height: 20),
            const Text(
              'GPS tracking active during journey.',
              style: TextStyle(
                color: Colors.blueGrey,
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompanySelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(5),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: _selectedCompanyId,
          isExpanded: true,
          icon: const Icon(Icons.business_rounded, color: Color(0xFF2563EB)),
          hint: const Text("Select Company"),
          onChanged: isTracking ? null : _onCompanyChanged,
          items:
              _companies.map((company) {
                return DropdownMenuItem<int>(
                  value: company['id'],
                  child: Text(
                    company['name'],
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1E293B),
                    ),
                  ),
                );
              }).toList(),
        ),
      ),
    );
  }

  Widget _buildStatusVisualizer(Size size) {
    final double diameter = size.width * (size.width > 600 ? 0.25 : 0.45);

    return Container(
      width: diameter,
      height: diameter,
      padding: EdgeInsets.all(diameter * 0.15),
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: (isTracking ? Colors.green : Colors.blueGrey).withAlpha(30),
            blurRadius: 40,
            spreadRadius: 10,
          ),
        ],
      ),
      child: Icon(
        isTracking ? Icons.location_on : Icons.location_off,
        size: diameter * 0.5,
        color: isTracking ? Colors.green : Colors.blueGrey.shade300,
      ),
    );
  }

  Widget _buildStartTimeBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.green.withAlpha(20),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        'Started at $_startTime',
        style: TextStyle(
          color: Colors.green.shade800,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
    );
  }

  Widget _buildMainActionButton() {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 400),
      child: ElevatedButton(
        onPressed:
            _isLoading ? null : (isTracking ? _endJourney : _startJourney),
        style: ElevatedButton.styleFrom(
          backgroundColor:
              isTracking ? Colors.red.shade600 : Colors.green.shade600,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 4,
        ),
        child:
            _isLoading
                ? const SizedBox(
                  height: 24,
                  width: 24,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 3,
                  ),
                )
                : Text(
                  isTracking ? 'End Journey' : 'Start Journey',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
      ),
    );
  }

  Widget _buildSessionWarningBanner() {
    return Container(
      width: double.infinity,
      color: Colors.orange.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.orange),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Session expired. Please login to sync data.',
              style: TextStyle(
                color: Colors.orange,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
            },
            child: const Text('Login'),
          ),
        ],
      ),
    );
  }
}
