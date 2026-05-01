import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'controller_page.dart';
import 'login_page.dart';
import 'services/session_service.dart';
import 'services/route_service.dart';
import 'services/websocket_service.dart';
import 'services/mqtt_device_service.dart';
import 'core/api_exception.dart';
import 'services/auth_service.dart';

class GridControlPage extends StatefulWidget {
  final String username;
  const GridControlPage({Key? key, required this.username}) : super(key: key);

  @override
  State<GridControlPage> createState() => _GridControlPageState();
}

class _GridControlPageState extends State<GridControlPage> {
  // Lokasi kapal — diupdate realtime dari telemetri Arduino via MQTT
  LatLng _shipLatLng = const LatLng(-2.9545457, 104.7482617);
  bool _locationLoaded = false;
  double _shipSpeed = 0.0;
  double _shipBearing = 0.0;

  // ── Telemetri tambahan dari Arduino v14.5-S3 ─────────────────────────────
  String _deviceMode       = 'idle';
  int    _motorSpeed       = 0;
  int    _waypointIndex    = 0;
  bool   _autopilotActive  = false;
  bool   _smartMoveActive  = false;
  int    _obstacleLeft     = 400;
  int    _obstacleRight    = 400;
  int    _gpsQuality       = 0;
  double _hdop             = 99.9;
  int    _satelliteCount   = 0;
  bool   _gpsFix           = false;
  double _lastHeading      = 0.0;

  // ── Telemetri baru dari Arduino v14.8-S3 (Navigation Grid) ──────────────
  int    _waypointCount    = 0;
  bool   _headingValid     = true;
  bool   _motorDisabled    = false;

  double _xte              = 0.0;
  double _arrivalRadius    = 3.0;
  int    _wpElapsedS       = 0;
  int    _wpTimeoutS       = 120;
  double _wpDistM          = 0.0;

  // ─── Telemetri baru dari Arduino v15.0-S3 (GSM + M8U Sensor Fusion) ────
  bool   _gsmConnected    = false;
  int    _signalQuality   = 0;
  double _drHeading       = 0.0;
  double _drHeadingAcc    = 999.0;
  bool   _drValid         = false;
  int    _fusionMode      = 0;

  List<LatLng> waypoints = [];
  bool isExecuting = false;
  bool isConnected = false;

  // Singleton services — tetap hidup saat pindah halaman
  final _sessionService = SessionService.instance;
  final _routeService = RouteService();
  final _wsService = WebSocketService.instance;
  final _mqttDevice = MqttDeviceService.instance;

  // flutter_map controller
  final MapController _mapController = MapController();
  String? _activeRouteId;

  StreamSubscription<bool>? _mqttRunningSub;
  StreamSubscription<WsConnectionState>? _wsStateSub;
  StreamSubscription<Map<String, dynamic>>? _navEventSub;

  @override
  void initState() {
    super.initState();

    // Listen WebSocket connection state
    _wsStateSub = _wsService.stateStream.listen((state) {
      if (mounted) {
        setState(() => isConnected = state == WsConnectionState.connected);
      }
    });
    // Sinkronkan state awal WebSocket
    isConnected = _wsService.state == WsConnectionState.connected;

    // Listen running state MQTT
    _mqttRunningSub = _mqttDevice.runningStream.listen((running) {
      if (mounted) setState(() {});
    });

    // Listen telemetri Arduino — update posisi kapal di peta
    _mqttDevice.telemetryNotifier.addListener(_onTelemetryUpdate);

    // Listen navigation events dari Arduino v14.8
    _navEventSub = _mqttDevice.navEventStream.listen(_onNavEvent);

    _initServices();
  }

  /// Hanya buka session & connect jika belum aktif
  Future<void> _initServices() async {
    if (_mqttDevice.isRunning && _wsService.state == WsConnectionState.connected) {
      debugPrint('[GRID] Services sudah aktif — skip reconnect');
      _onTelemetryUpdate();
      return;
    }

    // Jika session sudah ada tapi WS/MQTT mati, reconnect tanpa buat session baru
    if (_sessionService.hasSession) {
      debugPrint('[GRID] Session ada — reconnect WS & MQTT saja');
      if (_wsService.state != WsConnectionState.connected) {
        try { await _wsService.connect(); } catch (_) {}
      }
      if (!_mqttDevice.isRunning) {
        _mqttDevice.startAsync();
      }
      _onTelemetryUpdate();
      return;
    }

    await _openSessionAndConnect();
  }

  void _onTelemetryUpdate() {
    if (!mounted) return;
    final lat = _mqttDevice.arduinoLat;
    final lng = _mqttDevice.arduinoLng;
    if (lat == 0.0 && lng == 0.0) return;

    final newLatLng = LatLng(lat, lng);
    final isFirst = !_locationLoaded;

    setState(() {
      _shipLatLng      = newLatLng;
      _shipSpeed       = _mqttDevice.arduinoSpeed;
      _shipBearing     = _mqttDevice.arduinoBearing;
      _locationLoaded  = _mqttDevice.locationLoaded;

      // Telemetri tambahan v14.5-S3
      _deviceMode      = _mqttDevice.deviceMode;
      _motorSpeed      = _mqttDevice.motorSpeed;
      _waypointIndex   = _mqttDevice.waypointIndex;
      _autopilotActive = _mqttDevice.autopilotActive;
      _smartMoveActive = _mqttDevice.smartMoveActive;
      _obstacleLeft    = _mqttDevice.obstacleLeft;
      _obstacleRight   = _mqttDevice.obstacleRight;
      _gpsQuality      = _mqttDevice.gpsQuality;
      _hdop            = _mqttDevice.arduinoHdop;
      _satelliteCount  = _mqttDevice.satelliteCount;
      _gpsFix          = _mqttDevice.gpsFix;
      _lastHeading     = _mqttDevice.lastHeading;

      // Telemetri baru v14.8-S3 (Navigation Grid)
      _waypointCount   = _mqttDevice.waypointCount;
      _headingValid    = _mqttDevice.headingValid;
      _motorDisabled   = _mqttDevice.motorDisabled;

      _xte             = _mqttDevice.xte;
      _arrivalRadius   = _mqttDevice.arrivalRadius;
      _wpElapsedS      = _mqttDevice.wpElapsedS;
      _wpTimeoutS      = _mqttDevice.wpTimeoutS;
      _wpDistM         = _mqttDevice.wpDistM;

      // Telemetri baru v15.0-S3 (GSM + M8U Sensor Fusion)
      _gsmConnected   = _mqttDevice.gsmConnected;
      _signalQuality  = _mqttDevice.signalQuality;
      _drHeading      = _mqttDevice.drHeading;
      _drHeadingAcc   = _mqttDevice.drHeadingAcc;
      _drValid        = _mqttDevice.drValid;
      _fusionMode     = _mqttDevice.fusionMode;

      // Sinkronkan status executing dengan autopilot Arduino
      if (_autopilotActive && !isExecuting) {
        isExecuting = true;
      } else if (!_autopilotActive && isExecuting && _deviceMode != 'auto') {
        isExecuting = false;
      }
    });

    // Hanya geser kamera saat pertama kali dapat GPS dari Arduino
    if (isFirst && _mqttDevice.locationLoaded) {
      _mapController.move(newLatLng, 16.0);
    }
  }

  /// Handle navigation events dari Arduino v14.8 (wp_reached, wp_timeout, dll)
  void _onNavEvent(Map<String, dynamic> data) {
    if (!mounted) return;
    final event = (data['event'] ?? '').toString();
    final wpIdx = data['wp_index'] ?? 0;
    final wpTotal = data['wp_total'] ?? 0;
    final dist = (data['dist_m'] ?? 0.0).toDouble();

    String message;
    Color bgColor;
    IconData icon;

    switch (event) {
      case 'wp_reached':
        message = 'WP ${wpIdx + 1}/$wpTotal tercapai (${dist.toStringAsFixed(1)}m)';
        bgColor = const Color(0xFF10B981);
        icon = Icons.check_circle;
        break;
      case 'wp_timeout':
        message = 'WP ${wpIdx + 1}/$wpTotal TIMEOUT — di-skip!';
        bgColor = const Color(0xFFF59E0B);
        icon = Icons.timer_off;
        break;
      case 'route_complete':
        message = 'Rute selesai! Semua $wpTotal waypoint tercapai.';
        bgColor = const Color(0xFF10B981);
        icon = Icons.flag;
        setState(() => isExecuting = false);
        break;
      case 'route_start':
        message = 'Rute dimulai: $wpTotal waypoint';
        bgColor = const Color(0xFF06B6D4);
        icon = Icons.play_arrow;
        break;
      case 'route_stop':
        message = 'Rute dihentikan';
        bgColor = const Color(0xFFEF4444);
        icon = Icons.stop;
        setState(() => isExecuting = false);
        break;
      default:
        return; // event tidak dikenal, abaikan
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, color: Colors.white, size: 16),
            const SizedBox(width: 8),
            Expanded(child: Text(message, style: const TextStyle(fontSize: 12))),
          ],
        ),
        backgroundColor: bgColor,
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.only(
          bottom: 60,
          left: MediaQuery.of(context).size.width * 0.25,
          right: MediaQuery.of(context).size.width * 0.25,
        ),
      ),
    );
  }

  Future<void> _openSessionAndConnect() async {
    try {
      const deviceId = 'cfead5c1-4e4e-42da-af88-70620b8e3eac';
      final session = await _sessionService.openSession(deviceId);
      debugPrint('[Session] OK: ${session.sessionId}');
      await _wsService.connect();
      _mqttDevice.startAsync();
    } on ApiException catch (e) {
      if (mounted) {
        if (e.statusCode == 401) {
          // Backend belum support Firebase token — skip, jangan ganggu user
          debugPrint('[Session] Backend belum support Firebase token (401). Skip.');
          _mqttDevice.startAsync();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                e.statusCode == 409 ? 'Device sedang dipakai!' : e.message,
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        debugPrint('[Session] Error: $e');
        _mqttDevice.startAsync();
      }
    }
  }

  @override
  void dispose() {
    _mqttDevice.telemetryNotifier.removeListener(_onTelemetryUpdate);
    _mqttRunningSub?.cancel();
    _wsStateSub?.cancel();
    _navEventSub?.cancel();
    // JANGAN disconnect/dispose services di sini!
    // Services adalah singleton — tetap hidup saat pindah halaman.
    // Hanya di-teardown saat logout (lihat _showLogoutDialog).
    super.dispose();
  }

  void _onMapTap(TapPosition tapPosition, LatLng latlng) {
    if (!isExecuting) setState(() => waypoints.add(latlng));
  }

  void _removeLastWaypoint() {
    if (waypoints.isNotEmpty) setState(() => waypoints.removeLast());
  }

  void _clearAllWaypoints() {
    setState(() {
      waypoints.clear();
      isExecuting = false;
    });
  }

  Future<void> _executeRoute() async {
    if (waypoints.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Minimal 2 waypoint diperlukan.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    setState(() => isExecuting = true);
    try {
      const deviceId = 'cfead5c1-4e4e-42da-af88-70620b8e3eac';
      final route = await _routeService.createRoute(
        deviceId: deviceId,
        name: 'Route ${DateTime.now().millisecondsSinceEpoch}',
        waypoints: waypoints
            .map((w) => Waypoint(lat: w.latitude, lng: w.longitude))
            .toList(),
      );
      await _routeService.startRoute(route.id);
      _activeRouteId = route.id;
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => isExecuting = false);
        final msg = e.statusCode == 401
            ? 'Backend belum terhubung (token tidak dikenali).'
            : e.message;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => isExecuting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Gagal mengirim route.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _stopRoute() async {
    if (_activeRouteId != null) {
      try {
        await _routeService.stopRoute(_activeRouteId!);
      } catch (_) {}
      _activeRouteId = null;
    }
    setState(() {
      isExecuting = false;
    });
  }

  int get totalSegments => waypoints.length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF020617), Color(0xFF172554), Color(0xFF0f172a)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    children: [
                      SizedBox(width: 180, child: _buildRoutePanel()),
                      const SizedBox(width: 8),
                      Expanded(child: _buildMap()),
                      const SizedBox(width: 8),
                      SizedBox(width: 120, child: _buildControlPanel()),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── HEADER ───────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.5),
        border: Border(
          bottom: BorderSide(color: const Color(0xFF06B6D4).withOpacity(0.3)),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.anchor, color: Color(0xFF22D3EE), size: 20),
          const SizedBox(width: 8),
          const Text(
            'SPEDI',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Color(0xFFE0F2FE),
              letterSpacing: 2,
            ),
          ),
          const SizedBox(width: 12),
          _buildModeButton('MANUAL', false, () {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => ShipControllerPage(username: widget.username),
              ),
            );
          }),
          const SizedBox(width: 6),
          _buildModeButton('GRID', true, () {}),
          const Spacer(),
          // User
          Row(
            children: [
              const Icon(Icons.person, size: 13, color: Color(0xFF22D3EE)),
              const SizedBox(width: 4),
              Text(
                widget.username,
                style: const TextStyle(color: Color(0xFF67E8F9), fontSize: 11),
              ),
            ],
          ),
          const SizedBox(width: 12),
          // Device mode badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: _deviceMode == 'auto'
                  ? const Color(0xFF10B981).withOpacity(0.25)
                  : _deviceMode == 'manual'
                      ? const Color(0xFFF59E0B).withOpacity(0.25)
                      : Colors.black.withOpacity(0.3),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: _deviceMode == 'auto'
                    ? const Color(0xFF10B981)
                    : _deviceMode == 'manual'
                        ? const Color(0xFFF59E0B)
                        : const Color(0xFF475569),
                width: 1,
              ),
            ),
            child: Text(
              _deviceMode.toUpperCase(),
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: _deviceMode == 'auto'
                    ? const Color(0xFF10B981)
                    : _deviceMode == 'manual'
                        ? const Color(0xFFF59E0B)
                        : const Color(0xFF64748B),
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Satellite count + GPS quality
          Icon(
            _gpsFix ? Icons.gps_fixed : Icons.gps_not_fixed,
            color: _gpsQuality >= 3
                ? Colors.green
                : _gpsQuality >= 2
                    ? Colors.yellow
                    : Colors.orange,
            size: 14,
          ),
          const SizedBox(width: 4),
          Text(
            '${_satelliteCount}S Q$_gpsQuality',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.bold,
              color: _gpsFix ? const Color(0xFF67E8F9) : Colors.orange,
            ),
          ),
          const SizedBox(width: 8),
          // Connection dot
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: isConnected ? Colors.green : Colors.red,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.radio, color: Color(0xFF22D3EE), size: 14),
          const SizedBox(width: 12),
          // Emergency Stop
          GestureDetector(
            onTap: () async {
              await _stopRoute();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('EMERGENCY STOP'),
                    backgroundColor: Colors.red,
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFFDC2626),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFEF4444), width: 1.5),
              ),
              child: const Icon(
                Icons.power_settings_new,
                color: Colors.white,
                size: 16,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Logout
          GestureDetector(
            onTap: () => _showLogoutDialog(),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.3),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: const Color(0xFF06B6D4).withOpacity(0.3),
                ),
              ),
              child: const Icon(
                Icons.logout,
                color: Color(0xFF22D3EE),
                size: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showLogoutDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0f172a),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: const Color(0xFF06B6D4).withOpacity(0.3),
            width: 2,
          ),
        ),
        title: const Text(
          'Logout',
          style: TextStyle(color: Color(0xFF22D3EE), fontSize: 16),
        ),
        content: const Text(
          'Yakin ingin logout?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal', style: TextStyle(color: Colors.white70)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await _stopRoute();
                await _wsService.disconnect();
                await _mqttDevice.stop();
                await _sessionService.closeSession();
              } catch (_) {
                // Lanjut logout meski ada error di server/service
              } finally {
                // Logout: sign out Firebase + Google + clear ApiClient token
                await AuthService().logout();
                if (mounted) {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const LoginPage()),
                    (route) => false,
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF06B6D4),
            ),
            child: const Text('Logout'),
          ),
        ],
      ),
    );
  }

  Widget _buildModeButton(String label, bool isActive, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 12),
        decoration: BoxDecoration(
          color: isActive
              ? const Color(0xFF06B6D4).withOpacity(0.25)
              : Colors.black.withOpacity(0.3),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isActive
                ? const Color(0xFF22D3EE)
                : const Color(0xFF06B6D4).withOpacity(0.3),
            width: isActive ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: isActive
                ? const Color(0xFF22D3EE)
                : const Color(0xFF67E8F9).withOpacity(0.5),
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }

  // ─── MAP ──────────────────────────────────────────────────────────────────

  /// Konversi bearing ke radian untuk Transform.rotate ikon kapal
  double _bearingToRad(double bearing) => bearing * math.pi / 180.0;

  /// Bangun list Marker untuk flutter_map
  List<Marker> _buildMarkers() {
    final markers = <Marker>[];

    // Marker kapal — rotasi sesuai heading dari Arduino (0° = Utara)
    markers.add(
      Marker(
        point: _shipLatLng,
        width: 36,
        height: 36,
        child: Transform.rotate(
          angle: _bearingToRad(_shipBearing),
          child: const Icon(
            Icons.navigation,
            color: Color(0xFF22D3EE),
            size: 30,
            shadows: [Shadow(color: Colors.black54, blurRadius: 6)],
          ),
        ),
      ),
    );

    // Waypoint markers
    for (int i = 0; i < waypoints.length; i++) {
      final isLast = i == waypoints.length - 1;
      final isActive = _autopilotActive && i == _waypointIndex;
      final isCompleted = _autopilotActive && i < _waypointIndex;
      final idx = i; // capture untuk closure

      Color markerColor;
      if (isActive) {
        markerColor = const Color(0xFF10B981); // hijau — target aktif
      } else if (isCompleted) {
        markerColor = const Color(0xFF64748B); // abu — sudah dilewati
      } else if (isLast) {
        markerColor = const Color(0xFFF59E0B); // kuning — tujuan akhir
      } else {
        markerColor = const Color(0xFF22D3EE); // cyan — belum dicapai
      }

      markers.add(
        Marker(
          point: waypoints[i],
          width: isActive ? 42 : 36,
          height: isActive ? 42 : 36,
          child: GestureDetector(
            onTap: () {
              if (!isExecuting) setState(() => waypoints.removeAt(idx));
            },
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  Icons.location_on,
                  color: markerColor,
                  size: isActive ? 36 : 30,
                  shadows: [
                    Shadow(
                      color: isActive
                          ? const Color(0xFF10B981).withOpacity(0.6)
                          : Colors.black54,
                      blurRadius: isActive ? 10 : 6,
                    ),
                  ],
                ),
                Positioned(
                  top: isActive ? 6 : 4,
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      color: isCompleted ? Colors.white54 : Colors.white,
                      fontSize: isActive ? 10 : 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return markers;
  }

  /// Bangun Polyline rute kapal → waypoints
  /// Saat autopilot aktif: segmen yang sudah dilewati ditampilkan abu-abu,
  /// segmen aktif ditampilkan hijau, segmen sisa ditampilkan cyan.
  List<Polyline> _buildPolylines() {
    if (waypoints.isEmpty) return [];

    final polylines = <Polyline>[];

    if (_autopilotActive && _waypointIndex < waypoints.length) {
      // Segmen yang sudah dilewati (abu-abu, tipis)
      if (_waypointIndex > 0) {
        polylines.add(Polyline(
          points: waypoints.sublist(0, _waypointIndex),
          color: const Color(0xFF475569),
          strokeWidth: 2,
        ));
      }

      // Segmen aktif: kapal → waypoint target (hijau)
      polylines.add(Polyline(
        points: [_shipLatLng, waypoints[_waypointIndex]],
        color: const Color(0xFF10B981),
        strokeWidth: 3.5,
      ));

      // Segmen sisa (cyan)
      if (_waypointIndex < waypoints.length) {
        polylines.add(Polyline(
          points: waypoints.sublist(_waypointIndex),
          color: const Color(0xFF22D3EE),
          strokeWidth: 2.5,
        ));
      }
    } else {
      // Tidak autopilot — tampilkan rute penuh
      polylines.add(Polyline(
        points: [_shipLatLng, ...waypoints],
        color: const Color(0xFF22D3EE),
        strokeWidth: 3,
      ));
    }

    return polylines;
  }

  Widget _buildMap() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF06B6D4).withOpacity(0.5),
          width: 2,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          children: [
            // ── flutter_map dengan OpenStreetMap tile ──────────────────
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _shipLatLng,
                initialZoom: 16.0,
                onTap: _onMapTap,
                // Nonaktifkan rotation gesture agar tidak putar layar
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                ),
              ),
              children: [
                // Tile layer OpenStreetMap — standard light style
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.palcomtech.spedi',
                  // Atribusi wajib sesuai lisensi OSM
                  additionalOptions: const {},
                ),
                // Polyline rute
                PolylineLayer(polylines: _buildPolylines()),
                // Markers (kapal + waypoints)
                MarkerLayer(markers: _buildMarkers()),
              ],
            ),

            // ── Status banner: GPS + koneksi ──────────────────────────────
            Positioned(
              top: 8,
              left: 8,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // GPS info banner
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.75),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: _gpsStatusColor.withOpacity(0.5)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _locationLoaded ? Icons.gps_fixed : Icons.gps_not_fixed,
                              color: _gpsStatusColor,
                              size: 12,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _buildGpsLabel(),
                              style: TextStyle(
                                color: _gpsStatusColor,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                        if (_locationLoaded) ...[
                          const SizedBox(height: 2),
                          Text(
                            '${_shipLatLng.latitude.toStringAsFixed(5)}, ${_shipLatLng.longitude.toStringAsFixed(5)}  HDG:${_lastHeading.toStringAsFixed(0)}°'
                            '${_drValid ? '  DR:${_drHeading.toStringAsFixed(0)}°±${_drHeadingAcc.toStringAsFixed(0)}' : ''}',
                            style: const TextStyle(
                              color: Color(0xFF67E8F9),
                              fontSize: 9,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // Notifikasi masalah — muncul di bawah GPS banner
                  if (!_mqttDevice.isRunning) ...[
                    const SizedBox(height: 4),
                    _buildWarningChip(
                      Icons.cloud_off,
                      'MQTT tidak terhubung',
                      Colors.red,
                    ),
                  ],
                  if (_mqttDevice.isRunning && !_gpsFix) ...[
                    const SizedBox(height: 4),
                    _buildWarningChip(
                      Icons.satellite_alt,
                      'Menunggu GPS fix dari Arduino...',
                      Colors.orange,
                    ),
                  ],
                  if (_gpsFix && _gpsQuality < 2) ...[
                    const SizedBox(height: 4),
                    _buildWarningChip(
                      Icons.warning_amber_rounded,
                      'Sinyal GPS lemah (Q$_gpsQuality, ${_satelliteCount}sat)',
                      Colors.orange,
                    ),
                  ],
                  if (_motorDisabled) ...[
                    const SizedBox(height: 4),
                    _buildWarningChip(
                      Icons.power_off,
                      'MOTOR DISABLED (emergency stop)',
                      Colors.red,
                    ),
                  ],
                  if (_autopilotActive && !_headingValid) ...[
                    const SizedBox(height: 4),
                    _buildWarningChip(
                      Icons.explore_off,
                      'Heading stale — navigasi kurang akurat',
                      const Color(0xFFF59E0B),
                    ),
                  ],
                  if (!isConnected) ...[
                    const SizedBox(height: 4),
                    _buildWarningChip(
                      Icons.wifi_off,
                      'WebSocket terputus',
                      Colors.red,
                    ),
                  ],
                  if (_mqttDevice.isRunning && !_gsmConnected) ...[
                    const SizedBox(height: 4),
                    _buildWarningChip(
                      Icons.signal_cellular_off,
                      'GSM tidak terhubung — sinyal seluler hilang',
                      Colors.red,
                    ),
                  ],
                ],
              ),
            ),

            // Zoom + center buttons
            Positioned(
              top: 8,
              right: 8,
              child: Column(
                children: [
                  _buildMapBtn(Icons.add, () {
                    final zoom = _mapController.camera.zoom;
                    _mapController.move(_mapController.camera.center, zoom + 1);
                  }),
                  const SizedBox(height: 4),
                  _buildMapBtn(Icons.remove, () {
                    final zoom = _mapController.camera.zoom;
                    _mapController.move(_mapController.camera.center, zoom - 1);
                  }),
                  const SizedBox(height: 4),
                  _buildMapBtn(Icons.my_location, () {
                    _mapController.move(_shipLatLng, 16.0);
                  }),
                ],
              ),
            ),

            // Hint tap — di bawah agar tidak menghalangi peta
            if (waypoints.isEmpty && !isExecuting)
              Positioned(
                bottom: 28,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.55),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.touch_app, color: Color(0xFF67E8F9), size: 12),
                        SizedBox(width: 4),
                        Text(
                          'Tap peta untuk set tujuan',
                          style: TextStyle(color: Color(0xFF67E8F9), fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Obstacle avoidance warning overlay
            if (_smartMoveActive)
              Positioned(
                bottom: 40,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444).withOpacity(0.85),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: const Color(0xFFFCA5A5),
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            color: Colors.white, size: 14),
                        const SizedBox(width: 6),
                        Text(
                          'OBSTACLE AVOIDANCE  L:${_obstacleLeft}cm  R:${_obstacleRight}cm',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Waypoint counter
            if (waypoints.isNotEmpty)
              Positioned(
                bottom: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: const Color(0xFF22D3EE).withOpacity(0.4),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.place,
                        color: Color(0xFFF59E0B),
                        size: 12,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${waypoints.length} waypoint',
                        style: const TextStyle(
                          color: Color(0xFF67E8F9),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Atribusi OSM (wajib secara lisensi)
            Positioned(
              bottom: 4,
              left: 6,
              child: Text(
                '© OpenStreetMap contributors',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.45),
                  fontSize: 8,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.7),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: const Color(0xFF06B6D4).withOpacity(0.4)),
        ),
        child: Icon(icon, color: const Color(0xFF22D3EE), size: 16),
      ),
    );
  }

  // ─── ROUTE PANEL ──────────────────────────────────────────────────────────

  /// Status GPS deskriptif berdasarkan kondisi aktual
  String get _gpsStatusLabel {
    if (!_mqttDevice.isRunning) return 'MQTT OFFLINE';
    if (!_gpsFix) return 'NO FIX';
    if (_gpsQuality >= 3) return 'GOOD';
    if (_gpsQuality >= 2) return 'FAIR';
    return 'WEAK';
  }

  Color get _gpsStatusColor {
    if (!_mqttDevice.isRunning) return Colors.red;
    if (!_gpsFix) return Colors.orange;
    if (_gpsQuality >= 3) return Colors.green;
    if (_gpsQuality >= 2) return Colors.yellow;
    return Colors.orange;
  }

  Widget _buildRoutePanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title
        Container(
          padding: const EdgeInsets.only(bottom: 8),
          child: const Row(
            children: [
              Icon(Icons.alt_route, color: Color(0xFF22D3EE), size: 14),
              SizedBox(width: 6),
              Text(
                'ROUTE PLANNER',
                style: TextStyle(
                  color: Color(0xFF22D3EE),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ),
        // Origin + waypoints (scrollable)
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.4),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: const Color(0xFF06B6D4).withOpacity(0.3),
                width: 1,
              ),
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Origin
                  Row(
                    children: [
                      const Icon(
                        Icons.radio_button_checked,
                        color: Color(0xFF22D3EE),
                        size: 13,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'ORIGIN',
                              style: TextStyle(
                                color: Color(0xFF64748B),
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              _locationLoaded
                                  ? '${_shipLatLng.latitude.toStringAsFixed(4)}, ${_shipLatLng.longitude.toStringAsFixed(4)}'
                                  : 'Menunggu GPS...',
                              style: TextStyle(
                                color: _locationLoaded
                                    ? const Color(0xFF67E8F9)
                                    : Colors.orange,
                                fontSize: 10,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (waypoints.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Tap peta untuk tujuan',
                        style: TextStyle(
                          color: Color(0xFF475569),
                          fontSize: 10,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    )
                  else
                    ...waypoints.asMap().entries.map((e) {
                      final i = e.key;
                      final isLast = i == waypoints.length - 1;
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          children: [
                            Icon(
                              isLast ? Icons.location_on : Icons.trip_origin,
                              color: isLast
                                  ? const Color(0xFFF59E0B)
                                  : const Color(0xFF22D3EE),
                              size: 13,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'WP ${i + 1}',
                                    style: TextStyle(
                                      color: isLast
                                          ? const Color(0xFFF59E0B).withOpacity(0.7)
                                          : const Color(0xFF64748B),
                                      fontSize: 8,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  Text(
                                    '${e.value.latitude.toStringAsFixed(4)}, ${e.value.longitude.toStringAsFixed(4)}',
                                    style: TextStyle(
                                      color: isLast
                                          ? const Color(0xFFF59E0B)
                                          : const Color(0xFF67E8F9),
                                      fontSize: 9,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (!isExecuting)
                              GestureDetector(
                                onTap: () =>
                                    setState(() => waypoints.removeAt(i)),
                                child: Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF475569).withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Icon(
                                    Icons.close,
                                    color: Color(0xFF475569),
                                    size: 12,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // ── Compact telemetry grid ──────────────────────────────────────
        _buildTelemetryGrid(),
      ],
    );
  }

  /// Grid telemetri compact 3 kolom — diperkaya dengan data navigasi v14.8
  Widget _buildTelemetryGrid() {
    // Hitung progress timeout sebagai persentase
    final timeoutPct = _wpTimeoutS > 0
        ? (_wpElapsedS / _wpTimeoutS * 100).clamp(0, 100).toInt()
        : 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: const Color(0xFF06B6D4).withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Column(
        children: [
          // Row 1: GPS status | SAT | HDOP
          Row(
            children: [
              Expanded(child: _tinyCell(
                'GPS', _gpsStatusLabel,
                color: _gpsStatusColor,
              )),
              const SizedBox(width: 4),
              Expanded(child: _tinyCell(
                'SAT', '$_satelliteCount',
                color: _gpsQuality >= 2 ? Colors.green : Colors.orange,
              )),
              const SizedBox(width: 4),
              Expanded(child: _tinyCell(
                'HDOP', _hdop < 90 ? _hdop.toStringAsFixed(1) : '--',
                color: _hdop <= 2.5 ? Colors.green : _hdop <= 5.0 ? Colors.yellow : Colors.orange,
              )),
            ],
          ),
          const SizedBox(height: 6),
          // Row 2: SPD | MTR | WPT
          Row(
            children: [
              Expanded(child: _tinyCell(
                'SPD', _shipSpeed.toStringAsFixed(1),
              )),
              const SizedBox(width: 4),
              Expanded(child: _tinyCell(
                'MTR', '$_motorSpeed',
                color: _motorDisabled
                    ? Colors.red
                    : _motorSpeed != 0 ? const Color(0xFF22D3EE) : null,
              )),
              const SizedBox(width: 4),
              Expanded(child: _tinyCell(
                'WPT',
                _autopilotActive && _waypointCount > 0
                    ? '${_waypointIndex + 1}/$_waypointCount'
                    : _autopilotActive
                        ? '${_waypointIndex + 1}/${waypoints.length}'
                        : '${waypoints.length}',
                color: _autopilotActive ? const Color(0xFF10B981) : null,
              )),
            ],
          ),
          const SizedBox(height: 6),
          // Row 3: OBS-L | OBS-R | DIST (jarak ke WP)
          Row(
            children: [
              Expanded(child: _tinyCell(
                'OBS-L', '${_obstacleLeft}cm',
                color: _obstacleLeft < 35 ? Colors.red : _obstacleLeft < 80 ? Colors.orange : null,
              )),
              const SizedBox(width: 4),
              Expanded(child: _tinyCell(
                'OBS-R', '${_obstacleRight}cm',
                color: _obstacleRight < 35 ? Colors.red : _obstacleRight < 80 ? Colors.orange : null,
              )),
              const SizedBox(width: 4),
              Expanded(child: _tinyCell(
                'DIST',
                _autopilotActive ? '${_wpDistM.toStringAsFixed(1)}m' : '--',
                color: _autopilotActive ? const Color(0xFF22D3EE) : null,
              )),
            ],
          ),
          // Row 4 (hanya saat autopilot): XTE | RADIUS | TIMEOUT
          if (_autopilotActive) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(child: _tinyCell(
                  'XTE',
                  '${_xte.toStringAsFixed(1)}m',
                  color: _xte.abs() > 5.0
                      ? Colors.red
                      : _xte.abs() > 2.0
                          ? Colors.orange
                          : const Color(0xFF10B981),
                )),
                const SizedBox(width: 4),
                Expanded(child: _tinyCell(
                  'RAD',
                  '${_arrivalRadius.toStringAsFixed(1)}m',
                  color: const Color(0xFF67E8F9),
                )),
                const SizedBox(width: 4),
                Expanded(child: _tinyCell(
                  'TMO',
                  '${_wpElapsedS}s',
                  color: timeoutPct > 80
                      ? Colors.red
                      : timeoutPct > 50
                          ? Colors.orange
                          : null,
                )),
              ],
            ),
            // Timeout progress bar
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: _wpTimeoutS > 0 ? (_wpElapsedS / _wpTimeoutS).clamp(0.0, 1.0) : 0.0,
                minHeight: 3,
                backgroundColor: const Color(0xFF1E293B),
                valueColor: AlwaysStoppedAnimation<Color>(
                  timeoutPct > 80
                      ? Colors.red
                      : timeoutPct > 50
                          ? Colors.orange
                          : const Color(0xFF10B981),
                ),
              ),
            ),
          ],
          const SizedBox(height: 6),
          // Row 5: GSM | SIG | IMU (v15.0 — GSM + Sensor Fusion)
          Row(
            children: [
              Expanded(child: _tinyCell(
                'GSM', _gsmConnected ? 'ON' : 'OFF',
                color: _gsmConnected ? Colors.green : Colors.red,
              )),
              const SizedBox(width: 4),
              Expanded(child: _tinyCell(
                'SIG', '$_signalQuality/31',
                color: _signalQuality > 15
                    ? Colors.green
                    : _signalQuality > 8
                        ? Colors.yellow
                        : Colors.red,
              )),
              const SizedBox(width: 4),
              Expanded(child: _tinyCell(
                'IMU',
                _fusionMode == 2 ? 'FUSED'
                    : _fusionMode == 3 ? 'DR'
                    : _fusionMode == 1 ? 'CALIB'
                    : 'INIT',
                color: _fusionMode == 2
                    ? Colors.green
                    : _fusionMode == 3
                        ? Colors.orange
                        : _fusionMode == 1
                            ? Colors.yellow
                            : Colors.red,
              )),
            ],
          ),
        ],
      ),
    );
  }

  /// Cell telemetri compact — label di atas, value di bawah
  Widget _tinyCell(String label, String value, {Color? color}) {
    final c = color ?? const Color(0xFF67E8F9);
    return Column(
      children: [
        Text(label, style: const TextStyle(
          color: Color(0xFF64748B), fontSize: 8,
          fontWeight: FontWeight.w600, letterSpacing: 0.5,
        )),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(
          color: c, fontSize: 11,
          fontWeight: FontWeight.bold, fontFamily: 'monospace',
        )),
      ],
    );
  }

  /// Label GPS deskriptif berdasarkan kondisi
  String _buildGpsLabel() {
    if (!_mqttDevice.isRunning) return 'MQTT OFFLINE';
    if (!_gpsFix) return 'MENCARI SATELIT...';
    if (_gpsQuality >= 3) return 'GPS BAGUS  ${_satelliteCount}sat  HDOP:${_hdop.toStringAsFixed(1)}';
    if (_gpsQuality >= 2) return 'GPS CUKUP  ${_satelliteCount}sat  HDOP:${_hdop.toStringAsFixed(1)}';
    return 'GPS LEMAH  ${_satelliteCount}sat  HDOP:${_hdop.toStringAsFixed(1)}';
  }

  /// Chip peringatan kecil untuk notifikasi masalah
  Widget _buildWarningChip(IconData icon, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 11),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 9,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ─── CONTROL PANEL ────────────────────────────────────────────────────────

  Widget _buildControlPanel() {
    // Tentukan status label berdasarkan telemetri Arduino
    String statusLabel;
    Color statusColor;
    if (_autopilotActive) {
      if (_smartMoveActive) {
        statusLabel = 'AVOIDING';
        statusColor = const Color(0xFFEF4444);
      } else {
        statusLabel = 'NAVIGATING';
        statusColor = const Color(0xFFFBBF24);
      }
    } else if (isExecuting) {
      statusLabel = 'EXECUTING';
      statusColor = const Color(0xFFFBBF24);
    } else if (_deviceMode == 'manual') {
      statusLabel = 'MANUAL';
      statusColor = const Color(0xFFF59E0B);
    } else {
      statusLabel = 'READY';
      statusColor = const Color(0xFF10B981);
    }

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _actionBtn(
            'EXECUTE',
            Icons.play_arrow_rounded,
            waypoints.length >= 2 && !isExecuting,
            const Color(0xFF10B981),
            waypoints.length >= 2 && !isExecuting ? _executeRoute : null,
          ),
          const SizedBox(height: 8),
          _actionBtn(
            'STOP',
            Icons.stop_rounded,
            isExecuting || _autopilotActive,
            const Color(0xFFEF4444),
            isExecuting || _autopilotActive ? _stopRoute : null,
          ),
          const SizedBox(height: 8),
          _actionBtn(
            'UNDO',
            Icons.undo_rounded,
            waypoints.isNotEmpty && !isExecuting,
            const Color(0xFFF59E0B),
            waypoints.isNotEmpty && !isExecuting ? _removeLastWaypoint : null,
          ),
          const SizedBox(height: 8),
          _actionBtn(
            'RESET',
            Icons.refresh_rounded,
            !isExecuting,
            const Color(0xFF06B6D4),
            !isExecuting ? _clearAllWaypoints : null,
          ),
          const SizedBox(height: 12),
          // Status indicator — sinkron dengan Arduino
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.4),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: statusColor.withOpacity(0.5),
                width: 1.5,
              ),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: statusColor.withOpacity(0.6),
                            blurRadius: 4,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      statusLabel,
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
                if (_autopilotActive && waypoints.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    _waypointCount > 0
                        ? 'WP ${_waypointIndex + 1}/$_waypointCount'
                        : 'WP ${_waypointIndex + 1}/${waypoints.length}',
                    style: const TextStyle(
                      color: Color(0xFF67E8F9),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                    ),
                  ),
                  if (_wpDistM > 0) ...[
                    const SizedBox(height: 2),
                    Text(
                      '${_wpDistM.toStringAsFixed(1)}m',
                      style: const TextStyle(
                        color: Color(0xFF22D3EE),
                        fontSize: 9,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ],
                if (_motorDisabled) ...[
                  const SizedBox(height: 6),
                  const Text(
                    'MTR OFF',
                    style: TextStyle(
                      color: Colors.red,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionBtn(
    String label,
    IconData icon,
    bool enabled,
    Color color,
    VoidCallback? onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: enabled
              ? color.withOpacity(0.15)
              : Colors.black.withOpacity(0.3),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: enabled ? color.withOpacity(0.6) : const Color(0xFF1e293b),
            width: 1.5,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color: enabled ? color : const Color(0xFF334155),
              size: 22,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                color: enabled ? color : const Color(0xFF334155),
                fontSize: 9,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
