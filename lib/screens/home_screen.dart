import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/location_service.dart';
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
    _locationService.stopTracking(); // Ensure tracking stops if widget is destroyed
    super.dispose();
  }

  /// Initial data load: Companies and Active Journey
  Future<void> _initializeData() async {
    setState(() => _isInitializing = true);
    await Future.wait([
      _loadJourneyStatus(),
      _fetchUserCompanies(),
    ]);

    // Resume tracking if a journey was already active
    if (_activeJourneyId != null && _selectedCompanyId != null) {
      _locationService.startTracking(
        journeyId: _activeJourneyId!,
        companyId: _selectedCompanyId!,
      );
    }
    
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
    } else if (savedCompanyId != null && _companies.any((c) => c['id'] == savedCompanyId)) {
      _selectedCompanyId = savedCompanyId;
    } else if (_companies.isNotEmpty) {
      _selectedCompanyId = _companies.first['id'];
    }
  }

  Future<void> _loadJourneyStatus() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _activeJourneyId = prefs.getString('active_journey_id');
      _startTime = prefs.getString('journey_start_time');
    });
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
      // 2. Call Start API
      final response = await _apiService.post('/location/start', {
        'company_id': _selectedCompanyId,
        'start_lat': 0.0,
        'start_lng': 0.0,
      });

      if (response.success && response.data != null) {
        final dynamic journeyData = response.data['data'];
        final String journeyId = journeyData['id'].toString();
        
        final prefs = await SharedPreferences.getInstance();
        final now = DateTime.now();
        final startTimeStr = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
        
        await prefs.setString('active_journey_id', journeyId);
        await prefs.setString('journey_start_time', startTimeStr);
        await prefs.setInt('selected_company_id', _selectedCompanyId!);
        
        // 3. Start Real-time GPS Tracking Engine
        _locationService.startTracking(
          journeyId: journeyId,
          companyId: _selectedCompanyId!,
        );

        setState(() {
          _activeJourneyId = journeyId;
          _startTime = startTimeStr;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Journey started with GPS tracking'), backgroundColor: Colors.green),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response.message), backgroundColor: Colors.red),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to start journey'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Ends the journey and stops the background service
  Future<void> _endJourney() async {
    if (_activeJourneyId == null || _selectedCompanyId == null) return;

    setState(() => _isLoading = true);
    try {
      // 1. Stop GPS Tracking Engine First
      _locationService.stopTracking();

      // 2. Call End API
      final response = await _apiService.post('/location/end', {
        'journey_id': _activeJourneyId,
        'company_id': _selectedCompanyId,
        'end_lat': 0.0,
        'end_lng': 0.0,
      });

      if (response.success) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('active_journey_id');
        await prefs.remove('journey_start_time');
        
        setState(() {
          _activeJourneyId = null;
          _startTime = null;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Journey and tracking stopped'), backgroundColor: Colors.blue),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(response.message), backgroundColor: Colors.red),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to end journey'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _handleLogout() async {
    _locationService.stopTracking(); // Stop tracking on logout
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
        title: const Text('Journey Control', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            onPressed: _handleLogout,
            tooltip: 'Logout',
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
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
                    color: isTracking ? Colors.green.shade700 : Colors.blueGrey.shade700,
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
                  style: TextStyle(color: Colors.blueGrey, fontSize: 12, fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
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
          items: _companies.map((company) {
            return DropdownMenuItem<int>(
              value: company['id'],
              child: Text(
                company['name'],
                style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
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
        onPressed: _isLoading ? null : (isTracking ? _endJourney : _startJourney),
        style: ElevatedButton.styleFrom(
          backgroundColor: isTracking ? Colors.red.shade600 : Colors.green.shade600,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 4,
        ),
        child: _isLoading
            ? const SizedBox(
                height: 24,
                width: 24,
                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
              )
            : Text(
                isTracking ? 'End Journey' : 'Start Journey',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
      ),
    );
  }
}
