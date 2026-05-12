import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/location_service.dart';
import 'login_screen.dart';
import 'company_selection_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final ApiService _apiService = ApiService();
  final AuthService _authService = AuthService();
  final LocationTrackingService _locationService = LocationTrackingService();
  Timer? _syncTimer;

  bool _isLoading = false;
  bool _isInitializing = true;
  bool _isSessionValid = true;
  bool _isPermissionsGranted = false;
  String? _activeJourneyId;
  String? _startTime;
  int _heartbeatCount = 0;
  String _userName = "Employee";
  String _gpsQuality = "Waiting...";
  Color _gpsColor = Colors.grey;
  StreamSubscription<Position>? _positionStream;

  List<dynamic> _companies = [];
  int? _selectedCompanyId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeData();
    _startSyncTimer();
    _startGpsListener();
  }

  /// Listens to real-time GPS accuracy to update the Quality indicator
  void _startGpsListener() {
    _positionStream?.cancel();
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0, // We want quality updates even if stationary
      ),
    ).listen((Position position) {
      if (!mounted) return;
      _updateGpsQuality(position.accuracy);
    }, onError: (e) {
      debugPrint("GPS Listener Error: $e");
      if (mounted) {
        setState(() {
          _gpsQuality = "Offline";
          _gpsColor = Colors.red;
        });
      }
    });
  }

  void _updateGpsQuality(double accuracy) {
    setState(() {
      if (accuracy <= 12) {
        _gpsQuality = "Excellent";
        _gpsColor = Colors.green;
      } else if (accuracy <= 50) {
        _gpsQuality = "Good";
        _gpsColor = Colors.blue;
      } else if (accuracy <= 100) {
        _gpsQuality = "Fair";
        _gpsColor = Colors.orange;
      } else {
        _gpsQuality = "Poor";
        _gpsColor = Colors.redAccent;
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncActiveJourney();
      _startGpsListener(); // Restart listener when app returns to foreground
    } else if (state == AppLifecycleState.paused) {
      _positionStream?.cancel(); // Save battery when app is in background
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _positionStream?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _startSyncTimer() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (isTracking && !_isLoading) {
        _syncActiveJourney();
      }
    });
  }

  bool get isTracking => _activeJourneyId != null;

  Future<void> _initializeData() async {
    setState(() {
      _isInitializing = true;
      _isSessionValid = true;
    });

    // 1. Permissions
    _isPermissionsGranted = await _locationService.handlePermissions();
    if (!_isPermissionsGranted) {
      setState(() => _isInitializing = false);
      return;
    }

    // 2. Load Selected Company from Prefs
    final prefs = await SharedPreferences.getInstance();
    _selectedCompanyId = prefs.getInt('selected_company_id');

    // 3. Fetch User Profile
    final userDataStr = prefs.getString('user_data');
    if (userDataStr != null) {
      _userName = "Employee"; // Could parse from JSON if needed
    }

    // 4. Fetch/Sync Companies
    await _fetchUserCompaniesAndValidate();

    // 5. Sync Active Journey
    await _syncActiveJourney();

    // 6. AUTO-START Logic (Only if we have a selection)
    if (!isTracking && _selectedCompanyId != null && !_isLoading) {
      debugPrint("[AutoStart] Initiating tracking...");
      _startJourney();
    }

    setState(() => _isInitializing = false);

    // 7. Cache Monitor
    Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      setState(() {
        _heartbeatCount = prefs.getInt('cached_points_count') ?? 0;
      });
    });
  }

  Future<void> _fetchUserCompaniesAndValidate() async {
    try {
      final response = await _apiService.get('/companies/my');
      if (response.success && response.data is List) {
        _companies = response.data as List;
        
        if (_companies.isEmpty) {
          _showNoCompanyLogoutPopup();
          return;
        }

        // If user has multiple companies but hasn't picked one, send back to selection
        if (_selectedCompanyId == null && _companies.length > 1) {
          if (mounted) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => CompanySelectionScreen(companies: _companies)),
            );
          }
        } else if (_selectedCompanyId == null && _companies.length == 1) {
          // Auto-select the only one
          _selectedCompanyId = _companies.first['id'];
          final prefs = await SharedPreferences.getInstance();
          await prefs.setInt('selected_company_id', _selectedCompanyId!);
        }
      }
    } catch (e) {
      debugPrint("Company Fetch Error: $e");
    }
  }

  void _showNoCompanyLogoutPopup() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Access Denied'),
        content: const Text('No company assigned. Please contact your administrator.'),
        actions: [
          ElevatedButton(onPressed: () => _performLogout(force: true), child: const Text('Back to Login')),
        ],
      ),
    );
  }

  Future<void> _syncActiveJourney() async {
    try {
      final response = await _apiService.get('/location/active-journey');
      final prefs = await SharedPreferences.getInstance();

      if (response.success && response.data != null) {
        final dynamic journeyData = response.data;
        final String journeyId = journeyData['id'].toString();
        final int? companyId = journeyData['company_id'];
        final String? startTime = journeyData['start_time'];

        if (companyId != null) {
          await prefs.setString('active_journey_id', journeyId);
          await prefs.setInt('selected_company_id', companyId);

          setState(() {
            _activeJourneyId = journeyId;
            _selectedCompanyId = companyId;
            _startTime = _formatTime(startTime);
          });

          final service = FlutterBackgroundService();
          if (!(await service.isRunning())) {
            _resumeTracking();
          }
        }
      } else if (response.success && response.data == null) {
        if (isTracking) {
          debugPrint("[Sync] Journey terminated remotely. Logging out.");
          _performLogout(force: true);
        }
        await prefs.remove('active_journey_id');
        setState(() {
          _activeJourneyId = null;
          _startTime = null;
        });
      }
    } catch (e) {
      debugPrint("Sync Error: $e");
    }
  }

  String _formatTime(String? iso) {
    if (iso == null) return "N/A";
    try {
      final dt = DateTime.parse(iso).toLocal();
      return "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
    } catch (_) {
      return "N/A";
    }
  }

  Future<void> _startJourney() async {
    if (_selectedCompanyId == null || _isLoading) return;

    setState(() => _isLoading = true);
    try {
      final Position position = await _locationService.getCurrentLocation();
      final response = await _apiService.post('/location/start', {
        'company_id': _selectedCompanyId,
        'start_lat': position.latitude,
        'start_lng': position.longitude,
      });

      if (response.success && response.data != null) {
        final String journeyId = response.data['id'].toString();
        final String startTime = response.data['start_time'];

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('active_journey_id', journeyId);
        await prefs.setString('journey_start_time', _formatTime(startTime));

        setState(() {
          _activeJourneyId = journeyId;
          _startTime = _formatTime(startTime);
        });

        await FlutterBackgroundService().startService();
        _locationService.startTracking(
          journeyId: journeyId,
          companyId: _selectedCompanyId!,
        );
      }
    } catch (e) {
      debugPrint("Start Error: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _endJourney() async {
    if (_activeJourneyId == null || _selectedCompanyId == null) return;
    try {
      final Position position = await _locationService.getCurrentLocation();
      await _apiService.post('/location/end', {
        'journey_id': _activeJourneyId,
        'company_id': _selectedCompanyId,
        'end_lat': position.latitude,
        'end_lng': position.longitude,
      });
    } catch (e) {
      debugPrint("End Error: $e");
    }
  }

  void _resumeTracking() async {
    if (_activeJourneyId == null || _selectedCompanyId == null) return;
    await FlutterBackgroundService().startService();
    _locationService.startTracking(
      journeyId: _activeJourneyId!,
      companyId: _selectedCompanyId!,
    );
  }

  void _performLogout({bool force = false}) async {
    if (!force) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Logout'),
          content: const Text('Logging out will end your current tracking session. Continue?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Logout')),
          ],
        ),
      );
      if (confirm != true) return;
    }

    setState(() => _isLoading = true);
    await _endJourney();
    _locationService.stopTracking();
    FlutterBackgroundService().invoke("stopService");
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
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

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: CustomScrollView(
        slivers: [
          _buildPremiumSliverAppBar(),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              child: Column(
                children: [
                  if (!_isSessionValid) _buildSessionWarning(),
                  _buildTrackingStatusCard(),
                  const SizedBox(height: 24),
                  _buildStatsGrid(),
                  const SizedBox(height: 32),
                  _buildCompanyBadge(),
                  const SizedBox(height: 48),
                  _buildSyncFooter(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPremiumSliverAppBar() {
    return SliverAppBar(
      expandedHeight: 140,
      pinned: true,
      elevation: 0,
      backgroundColor: Colors.indigo.shade900,
      leading: const SizedBox.shrink(), // Remove back arrow
      flexibleSpace: FlexibleSpaceBar(
        centerTitle: false,
        titlePadding: const EdgeInsets.only(left: 20, bottom: 16),
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Field Track', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: Colors.white)),
            Text('Hello, $_userName', style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.normal)),
          ],
        ),
        background: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.indigo.shade900, Colors.indigo.shade700],
              begin: Alignment.topLeft, end: Alignment.bottomRight,
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                top: -30, right: -30,
                child: Icon(Icons.gps_fixed, size: 180, color: Colors.white.withAlpha(10)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.logout_rounded, color: Colors.white),
          onPressed: _performLogout,
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildTrackingStatusCard() {
    final color = isTracking ? const Color(0xFF10B981) : const Color(0xFF64748B);
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 20, offset: const Offset(0, 10))],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                    const SizedBox(width: 8),
                    Text(isTracking ? 'TRACKING ACTIVE' : 'SYSTEM IDLE', style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 11, letterSpacing: 1.1)),
                  ],
                ),
                const SizedBox(height: 12),
                const Text('Duty Status', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1E293B))),
                const SizedBox(height: 4),
                Text(isTracking ? 'Your location is being synced live.' : 'Ready for next assignment.', style: const TextStyle(color: Colors.grey, fontSize: 14)),
              ],
            ),
          ),
          _buildRadarCircle(color),
        ],
      ),
    );
  }

  Widget _buildRadarCircle(Color color) {
    return Container(
      width: 64, height: 64,
      decoration: BoxDecoration(color: color.withAlpha(15), shape: BoxShape.circle),
      child: isTracking ? const RadarPulse() : Icon(Icons.location_disabled_rounded, color: color, size: 28),
    );
  }

  Widget _buildStatsGrid() {
    return Row(
      children: [
        _buildStatCard('Start Time', _startTime ?? '--:--', Icons.watch_later_outlined, Colors.indigo),
        const SizedBox(width: 16),
        _buildStatCard('GPS Quality', _gpsQuality, Icons.gps_fixed_rounded, _gpsColor),
      ],
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: const Color(0xFFF1F5F9))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: color.withAlpha(15), borderRadius: BorderRadius.circular(10)), child: Icon(icon, color: color, size: 18)),
            const SizedBox(height: 16),
            Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E293B))),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  Widget _buildCompanyBadge() {
    String name = "Loading...";
    if (_companies.isNotEmpty && _selectedCompanyId != null) {
      final comp = _companies.firstWhere((c) => c['id'] == _selectedCompanyId, orElse: () => null);
      if (comp != null) name = comp['name'];
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          const Icon(Icons.business_center_rounded, size: 20, color: Color(0xFF64748B)),
          const SizedBox(width: 12),
          Expanded(child: Text(name, style: const TextStyle(color: Color(0xFF475569), fontWeight: FontWeight.w600))),
          const Icon(Icons.verified_user_rounded, color: Colors.indigo, size: 18),
        ],
      ),
    );
  }

  Widget _buildSyncFooter() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_done_rounded, size: 16, color: _heartbeatCount == 0 ? Colors.green : Colors.orange),
            const SizedBox(width: 8),
            Text(
              _heartbeatCount == 0 ? 'Data synchronized' : 'Syncing $_heartbeatCount data points...',
              style: TextStyle(color: _heartbeatCount == 0 ? Colors.green : Colors.orange, fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ],
        ),
        if (_isLoading) const Padding(padding: EdgeInsets.only(top: 16), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.indigo))),
      ],
    );
  }

  Widget _buildSessionWarning() => Container(margin: const EdgeInsets.only(bottom: 20), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(12)), child: const Text("Session Expired. Please login.", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)));
}

class RadarPulse extends StatefulWidget {
  const RadarPulse({super.key});
  @override
  State<RadarPulse> createState() => _RadarPulseState();
}

class _RadarPulseState extends State<RadarPulse> with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
  }
  @override
  void dispose() { _c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) => CustomPaint(painter: RadarPulsePainter(_c.value), child: const Center(child: Icon(Icons.my_location_rounded, color: Color(0xFF10B981), size: 24))),
    );
  }
}

class RadarPulsePainter extends CustomPainter {
  final double v;
  RadarPulsePainter(this.v);
  @override
  void paint(Canvas c, Size s) {
    final p1 = Paint()..color = const Color(0xFF10B981).withOpacity(1.0 - v)..style = PaintingStyle.stroke..strokeWidth = 2;
    c.drawCircle(Offset(s.width/2, s.height/2), (s.width/2) * v, p1);
    final p2 = Paint()..color = const Color(0xFF10B981).withOpacity((1.0 - v) * 0.4)..style = PaintingStyle.fill;
    c.drawCircle(Offset(s.width/2, s.height/2), (s.width/2) * v, p2);
  }
  @override
  bool shouldRepaint(CustomPainter old) => true;
}
