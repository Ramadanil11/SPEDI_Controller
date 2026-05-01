import 'dart:async';
import 'package:flutter/material.dart';
import 'login_page.dart';
import 'dart:math' as math;
import 'grid_control_page.dart';
import 'services/session_service.dart';
import 'services/websocket_service.dart';
import 'services/mqtt_device_service.dart';
import 'core/api_exception.dart';
import 'services/auth_service.dart';

class ShipControllerPage extends StatefulWidget {
  final String username;
  const ShipControllerPage({super.key, required this.username});

  @override
  State<ShipControllerPage> createState() => _ShipControllerPageState();
}

class _ShipControllerPageState extends State<ShipControllerPage> {
  double throttleValue = 0.0;
  double steeringValue = 0.0;
  bool isConnected = false;
  double speed = 0.0;
  int heading = 0;       // 0 = lurus utara, dari Arduino
  double latitude = 0.0;
  double longitude = 0.0;
  int satellites = 0;
  bool _gpsFixed = false;
  int _gpsQuality = 0;
  double _hdop = 99.9;
  int _obstacleLeft = 400;
  int _obstacleRight = 400;

  // ── Telemetri v15.0-S3 (GSM + Sensor Fusion) ──────────────────────────
  bool   _gsmConnected   = false;
  int    _signalQuality  = 0;
  int    _fusionMode     = 0;

  // Singleton services — tetap hidup saat pindah halaman
  final _sessionService = SessionService.instance;
  final _wsService = WebSocketService.instance;
  final _mqttDevice = MqttDeviceService.instance;

  StreamSubscription<WsConnectionState>? _wsStateSub;

  @override
  void initState() {
    super.initState();
    _initServices();
    _wsStateSub = _wsService.stateStream.listen((state) {
      if (mounted) setState(() => isConnected = state == WsConnectionState.connected);
    });
    // Sinkronkan state awal WebSocket
    isConnected = _wsService.state == WsConnectionState.connected;
    // Terima telemetri GPS dari Arduino via MQTT (menggunakan telemetryNotifier)
    _mqttDevice.telemetryNotifier.addListener(_onTelemetryUpdate);
  }

  /// Hanya buka session & connect jika belum aktif
  Future<void> _initServices() async {
    // Jika semua services sudah aktif, langsung pakai
    if (_mqttDevice.isRunning && _wsService.state == WsConnectionState.connected) {
      debugPrint('[MANUAL] Services sudah aktif — skip reconnect');
      _onTelemetryUpdate();
      return;
    }

    // Jika session sudah ada tapi WS/MQTT mati, reconnect tanpa buat session baru
    if (_sessionService.hasSession) {
      debugPrint('[MANUAL] Session ada — reconnect WS & MQTT saja');
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
    setState(() {
      latitude       = lat;
      longitude      = lng;
      speed          = _mqttDevice.arduinoSpeed;
      heading        = _mqttDevice.lastHeading.round();
      satellites     = _mqttDevice.satelliteCount;
      _gpsFixed      = _mqttDevice.gpsFix;
      _gpsQuality    = _mqttDevice.gpsQuality;
      _hdop          = _mqttDevice.arduinoHdop;
      _obstacleLeft  = _mqttDevice.obstacleLeft;
      _obstacleRight = _mqttDevice.obstacleRight;
      _gsmConnected  = _mqttDevice.gsmConnected;
      _signalQuality = _mqttDevice.signalQuality;
      _fusionMode    = _mqttDevice.fusionMode;
    });
  }

  Future<void> _openSessionAndConnect() async {
    try {
      const deviceId = 'cfead5c1-4e4e-42da-af88-70620b8e3eac';
      final session = await _sessionService.openSession(deviceId);
      print('[Session] OK: ${session.sessionId}');
      await _wsService.connect();
      _mqttDevice.startAsync();
    } on ApiException catch (e) {
      if (mounted) {
        if (e.statusCode == 401) {
          // Backend belum support Firebase token — skip, jangan ganggu user
          debugPrint('[Session] Backend belum support Firebase token (401). Skip.');
          // Tetap coba connect MQTT langsung (tidak butuh backend session)
          _mqttDevice.startAsync();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.statusCode == 409 ? 'Device sedang dipakai!' : e.message),
            backgroundColor: Colors.red,
          ));
        }
      }
    } catch (e) {
      if (mounted) {
        debugPrint('[Session] Error: $e');
        // Tetap coba MQTT meskipun session gagal
        _mqttDevice.startAsync();
      }
    }
  }

  @override
  void dispose() {
    _mqttDevice.telemetryNotifier.removeListener(_onTelemetryUpdate);
    _wsStateSub?.cancel();
    // JANGAN disconnect/dispose services di sini!
    // Services adalah singleton — tetap hidup saat pindah halaman.
    // Hanya di-teardown saat logout (lihat _showLogoutDialog).
    super.dispose();
  }

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
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

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
          const Text('SPEDI',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFE0F2FE),
                  letterSpacing: 2)),
          const SizedBox(width: 12),
          _buildModeBtn('MANUAL', true, () {}),
          const SizedBox(width: 6),
          _buildModeBtn('GRID', false, () {
            Navigator.of(context).pushReplacement(MaterialPageRoute(
              builder: (_) => GridControlPage(username: widget.username),
            ));
          }),
          const Spacer(),
          // Connection status
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(
              color: isConnected ? Colors.green : Colors.red,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.radio, color: Color(0xFF22D3EE), size: 14),
          const SizedBox(width: 12),
          Text('N $heading°',
              style: const TextStyle(color: Color(0xFF67E8F9), fontSize: 11)),
          const SizedBox(width: 12),
          // User
          Row(children: [
            const Icon(Icons.person, size: 13, color: Color(0xFF22D3EE)),
            const SizedBox(width: 4),
            Text(widget.username,
                style: const TextStyle(color: Color(0xFF67E8F9), fontSize: 11)),
          ]),
          const SizedBox(width: 12),
          // Emergency Stop
          GestureDetector(
            onTap: () {
              setState(() { throttleValue = 0; steeringValue = 0; speed = 0; });
              _wsService.sendStop();
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('EMERGENCY STOP'),
                backgroundColor: Colors.red,
                duration: Duration(seconds: 2),
              ));
            },
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFFDC2626),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFEF4444), width: 1.5),
              ),
              child: const Icon(Icons.power_settings_new, color: Colors.white, size: 16),
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
                border: Border.all(color: const Color(0xFF06B6D4).withOpacity(0.3)),
              ),
              child: const Icon(Icons.logout, color: Color(0xFF22D3EE), size: 16),
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
          side: BorderSide(color: const Color(0xFF06B6D4).withOpacity(0.3), width: 2),
        ),
        title: const Text('Logout', style: TextStyle(color: Color(0xFF22D3EE), fontSize: 16)),
        content: const Text('Yakin ingin logout?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal', style: TextStyle(color: Colors.white70)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                _wsService.sendStop();
                await _wsService.disconnect();
                await _mqttDevice.stop();
                await _sessionService.closeSession();
              } catch (_) {
                // Lanjut logout meski ada error di server/service
              } finally {
                // Logout: sign out Supabase + Google + clear ApiClient token
                await AuthService().logout();
                if (mounted) {
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const LoginPage()),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF06B6D4)),
            child: const Text('Logout'),
          ),
        ],
      ),
    );
  }

  Widget _buildModeBtn(String label, bool isActive, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 12),
        decoration: BoxDecoration(
          color: isActive ? const Color(0xFF06B6D4).withOpacity(0.25) : Colors.black.withOpacity(0.3),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isActive ? const Color(0xFF22D3EE) : const Color(0xFF06B6D4).withOpacity(0.3),
            width: isActive ? 1.5 : 1,
          ),
        ),
        child: Text(label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: isActive ? const Color(0xFF22D3EE) : const Color(0xFF67E8F9).withOpacity(0.5),
              letterSpacing: 1,
            )),
      ),
    );
  }

  Widget _buildBody() {
    return Row(
      children: [
        // Throttle
        SizedBox(width: 130, child: _buildThrottleControl()),
        // Center: GPS map
        Expanded(child: _buildGPSPanel()),
        // Steering
        SizedBox(width: 130, child: _buildSteeringControl()),
      ],
    );
  }

  Widget _buildGPSPanel() {
    return Container(
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF06B6D4).withOpacity(0.4), width: 1.5),
      ),
      // ClipRRect agar efek sonar/obstacle tidak keluar dari rounded container
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: Column(
          children: [
            // Title bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: const Color(0xFF06B6D4).withOpacity(0.15))),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(children: [
                    Icon(Icons.radar, color: Color(0xFF22D3EE), size: 14),
                    SizedBox(width: 6),
                    Text('GPS TRACKING',
                        style: TextStyle(color: Color(0xFF22D3EE), fontSize: 11,
                            fontWeight: FontWeight.bold, letterSpacing: 1)),
                  ]),
                  Row(children: [
                    Container(
                      width: 7, height: 7,
                      decoration: BoxDecoration(
                        color: !_mqttDevice.isRunning ? Colors.red
                             : _gpsQuality >= 3 ? Colors.green
                             : _gpsQuality >= 2 ? Colors.yellow
                             : Colors.orange,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      !_mqttDevice.isRunning ? 'OFFLINE'
                      : !_gpsFixed ? 'NO FIX'
                      : '$satellites SAT Q$_gpsQuality',
                      style: TextStyle(
                        color: !_mqttDevice.isRunning ? Colors.red
                             : _gpsFixed ? Colors.green : Colors.orange,
                        fontSize: 10, fontWeight: FontWeight.bold,
                      ),
                    ),
                  ]),
                ],
              ),
            ),
            // Radar area + obstacle visualization
            Expanded(
              child: LayoutBuilder(builder: (ctx, constraints) {
                return ClipRect(
                  child: Stack(
                    children: [
                      Positioned.fill(child: CustomPaint(painter: GridPainter())),
                      Center(child: CustomPaint(
                        painter: RadarPainter(),
                        size: Size(constraints.maxWidth * 0.7, constraints.maxHeight * 0.9),
                      )),
                      // Obstacle arcs — kiri dan kanan kapal
                      Center(child: CustomPaint(
                        painter: ObstaclePainter(
                          leftDist: _obstacleLeft,
                          rightDist: _obstacleRight,
                          headingDeg: heading.toDouble(),
                        ),
                        size: Size(constraints.maxWidth * 0.7, constraints.maxHeight * 0.9),
                      )),
                      // Ikon kapal
                      Center(
                        child: Transform.rotate(
                          angle: heading * math.pi / 180,
                          child: const Icon(Icons.navigation, color: Color(0xFF22D3EE), size: 32,
                              shadows: [Shadow(color: Color(0xFF06B6D4), blurRadius: 12)]),
                        ),
                      ),
                      // Label obstacle kiri
                      Positioned(
                        left: 8, top: 8,
                        child: _buildObstacleLabel('L', _obstacleLeft),
                      ),
                      // Label obstacle kanan
                      Positioned(
                        right: 8, top: 8,
                        child: _buildObstacleLabel('R', _obstacleRight),
                      ),
                      // Koordinat
                      Positioned(
                        bottom: 8, left: 8, right: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.7),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              Text('LAT: ${latitude.toStringAsFixed(4)}',
                                  style: const TextStyle(color: Color(0xFF67E8F9), fontSize: 10, fontFamily: 'monospace')),
                              Text('LNG: ${longitude.toStringAsFixed(4)}',
                                  style: const TextStyle(color: Color(0xFF67E8F9), fontSize: 10, fontFamily: 'monospace')),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
            // Status bar bawah — 1 baris: navigasi utama saja
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: const Color(0xFF06B6D4).withOpacity(0.2))),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildStatChip('SPEED', '${speed.toStringAsFixed(1)} km/h'),
                  _buildStatChip('HEADING', '$heading°'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildObstacleLabel(String side, int dist) {
    Color c;
    if (dist < 35) {
      c = Colors.red;
    } else if (dist < 80) {
      c = Colors.orange;
    } else {
      c = const Color(0xFF475569);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.withOpacity(0.6)),
      ),
      child: Text(
        '$side: ${dist}cm',
        style: TextStyle(color: c, fontSize: 9, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
      ),
    );
  }

  Widget _buildStatChip(String label, String value, {Color? valueColor}) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: Color(0xFF22D3EE), fontSize: 8, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(color: valueColor ?? const Color(0xFF67E8F9), fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
      ],
    );
  }

  /// Cell mini untuk panel telemetri di bawah joystick
  Widget _buildMiniCell(String label, String value, Color valueColor) {
    return Column(
      children: [
        Text(label, style: const TextStyle(
          color: Color(0xFF64748B), fontSize: 8,
          fontWeight: FontWeight.w600, letterSpacing: 0.5,
        )),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(
          color: valueColor, fontSize: 11,
          fontWeight: FontWeight.bold, fontFamily: 'monospace',
        )),
      ],
    );
  }

  Widget _buildThrottleControl() {
    // Warna kondisional untuk telemetri GPS
    final satColor = _gpsQuality >= 2 ? Colors.green : Colors.orange;
    final hdopColor = _hdop <= 2.5 ? Colors.green : _hdop <= 5.0 ? Colors.yellow : Colors.orange;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      child: Column(
        children: [
          const Spacer(flex: 2),
          const Text('THROTTLE',
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                  color: Color(0xFF67E8F9), letterSpacing: 1)),
          const SizedBox(height: 8),
          JoystickWidget(
            size: 130,
            isVertical: true,
            value: throttleValue,
            onChanged: (v) {
              setState(() { throttleValue = v; speed = v.abs() * 25 / 100; });
              _wsService.sendJoystick(throttle: throttleValue.toInt(), steering: steeringValue.toInt());
            },
            icon: Icons.waves,
          ),
          const SizedBox(height: 8),
          Text('${throttleValue > 0 ? '+' : ''}${throttleValue.toInt()}%',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                  color: Color(0xFF67E8F9), fontFamily: 'monospace')),
          const Spacer(flex: 1),
          // Panel info GPS
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.4),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF06B6D4).withOpacity(0.3)),
            ),
            child: Column(
              children: [
                const Text('GPS', style: TextStyle(
                  color: Color(0xFF22D3EE), fontSize: 9,
                  fontWeight: FontWeight.bold, letterSpacing: 1,
                )),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildMiniCell('SAT', '$satellites', satColor),
                    _buildMiniCell('HDOP', _hdop < 90 ? _hdop.toStringAsFixed(1) : '--', hdopColor),
                  ],
                ),
                const SizedBox(height: 4),
                _buildMiniCell('SPD', '${speed.toStringAsFixed(1)} km/h', const Color(0xFF67E8F9)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSteeringControl() {
    // Warna kondisional untuk telemetri konektivitas
    final gsmColor = _gsmConnected ? Colors.green : Colors.red;
    final sigColor = _signalQuality > 15 ? Colors.green : _signalQuality > 8 ? Colors.yellow : Colors.red;
    final imuColor = _fusionMode == 2 ? Colors.green : _fusionMode == 3 ? Colors.orange : _fusionMode == 1 ? Colors.yellow : Colors.red;
    final imuLabel = _fusionMode == 2 ? 'FUSED' : _fusionMode == 3 ? 'DR' : _fusionMode == 1 ? 'CALIB' : 'INIT';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      child: Column(
        children: [
          const Spacer(flex: 2),
          const Text('STEERING',
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                  color: Color(0xFF67E8F9), letterSpacing: 1)),
          const SizedBox(height: 8),
          JoystickWidget(
            size: 130,
            isVertical: false,
            value: steeringValue,
            onChanged: (v) {
              setState(() { steeringValue = v; });
              _wsService.sendJoystick(throttle: throttleValue.toInt(), steering: steeringValue.toInt());
            },
            icon: Icons.navigation,
          ),
          const SizedBox(height: 8),
          Text('${steeringValue > 0 ? '+' : ''}${steeringValue.toInt()}%',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                  color: Color(0xFF67E8F9), fontFamily: 'monospace')),
          const Spacer(flex: 1),
          // Panel info konektivitas
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.4),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF06B6D4).withOpacity(0.3)),
            ),
            child: Column(
              children: [
                const Text('LINK', style: TextStyle(
                  color: Color(0xFF22D3EE), fontSize: 9,
                  fontWeight: FontWeight.bold, letterSpacing: 1,
                )),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildMiniCell('GSM', _gsmConnected ? 'ON' : 'OFF', gsmColor),
                    _buildMiniCell('SIG', '$_signalQuality/31', sigColor),
                  ],
                ),
                const SizedBox(height: 4),
                _buildMiniCell('IMU', imuLabel, imuColor),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============ GRID PAINTER ============
class GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF06B6D4).withOpacity(0.1)
      ..strokeWidth = 1;
    for (int i = 0; i < 10; i++) {
      double x = (size.width / 10) * i;
      double y = (size.height / 10) * i;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter o) => false;
}

// ============ RADAR PAINTER ============
class RadarPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5;
    for (int i = 1; i <= 3; i++) {
      paint.color = const Color(0xFF06B6D4).withOpacity(0.3 - (i * 0.08));
      canvas.drawCircle(center, (size.width / 6) * i, paint);
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter o) => false;
}

// ============ OBSTACLE PAINTER ============
// Menggambar arc di kiri dan kanan radar untuk menunjukkan jarak halangan.
// Semakin dekat halangan, arc semakin tebal dan merah.
// > 80cm = tidak tampil (aman), 35-80cm = orange, < 35cm = merah tebal.
class ObstaclePainter extends CustomPainter {
  final int leftDist;
  final int rightDist;
  final double headingDeg;

  ObstaclePainter({
    required this.leftDist,
    required this.rightDist,
    required this.headingDeg,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2;

    // Rotasi canvas sesuai heading kapal
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(headingDeg * math.pi / 180.0);
    canvas.translate(-center.dx, -center.dy);

    _drawObstacleArc(canvas, center, maxR, leftDist, true);   // kiri
    _drawObstacleArc(canvas, center, maxR, rightDist, false);  // kanan

    canvas.restore();
  }

  void _drawObstacleArc(Canvas canvas, Offset center, double maxR, int dist, bool isLeft) {
    if (dist >= 400) return; // tidak ada halangan terdeteksi

    // Hitung intensitas: semakin dekat, semakin kuat
    // 0cm → 1.0, 80cm → 0.0, >80cm → masih tampil tipis sampai 200cm
    double intensity = ((200.0 - dist.clamp(0, 200)) / 200.0);

    Color arcColor;
    double strokeW;
    if (dist < 35) {
      // CRITICAL — merah tebal, berkedip efek
      arcColor = const Color(0xFFEF4444).withOpacity(0.9);
      strokeW = 8.0 + intensity * 6.0;
    } else if (dist < 80) {
      // WARNING — orange
      arcColor = const Color(0xFFF59E0B).withOpacity(0.4 + intensity * 0.4);
      strokeW = 4.0 + intensity * 4.0;
    } else {
      // FAR — tipis, hijau/cyan
      arcColor = const Color(0xFF22D3EE).withOpacity(intensity * 0.3);
      strokeW = 2.0 + intensity * 2.0;
    }

    // Radius arc: dekat = arc kecil (dekat kapal), jauh = arc besar
    // Map dist 0-200cm ke radius 30%-90% dari maxR
    double radiusFrac = 0.3 + (dist.clamp(0, 200) / 200.0) * 0.6;
    double arcRadius = maxR * radiusFrac;

    final paint = Paint()
      ..color = arcColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeW
      ..strokeCap = StrokeCap.round;

    // Arc sweep: kiri = 210°-330° (sisi kiri), kanan = 30°-150° (sisi kanan)
    // Dalam radian dari atas (0° = utara/atas)
    double startAngle;
    double sweepAngle = 60.0 * math.pi / 180.0; // 60 derajat arc

    if (isLeft) {
      startAngle = -150.0 * math.pi / 180.0; // kiri atas
    } else {
      startAngle = 90.0 * math.pi / 180.0;   // kanan bawah... no
    }

    // Pakai koordinat dari atas: kiri = -90° ± 30°, kanan = +90° ± 30°
    if (isLeft) {
      startAngle = (-90.0 - 30.0) * math.pi / 180.0;
    } else {
      startAngle = (90.0 - 30.0) * math.pi / 180.0;
    }

    final rect = Rect.fromCircle(center: center, radius: arcRadius);
    canvas.drawArc(rect, startAngle, sweepAngle, false, paint);

    // Gambar arc kedua lebih dekat untuk efek "zona bahaya" berlapis
    if (dist < 80) {
      double innerRadius = arcRadius * 0.7;
      final innerPaint = Paint()
        ..color = arcColor.withOpacity(arcColor.opacity * 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeW * 0.6
        ..strokeCap = StrokeCap.round;
      final innerRect = Rect.fromCircle(center: center, radius: innerRadius);
      canvas.drawArc(innerRect, startAngle, sweepAngle, false, innerPaint);
    }
  }

  @override
  bool shouldRepaint(covariant ObstaclePainter old) =>
      old.leftDist != leftDist ||
      old.rightDist != rightDist ||
      old.headingDeg != headingDeg;
}

// ============ JOYSTICK WIDGET ============
class JoystickWidget extends StatefulWidget {
  final double size;
  final bool isVertical;
  final double value;
  final ValueChanged<double> onChanged;
  final IconData icon;

  const JoystickWidget({
    Key? key,
    required this.size,
    required this.isVertical,
    required this.value,
    required this.onChanged,
    required this.icon,
  }) : super(key: key);

  @override
  State<JoystickWidget> createState() => _JoystickWidgetState();
}

class _JoystickWidgetState extends State<JoystickWidget> {
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanUpdate: (details) {
        RenderBox box = context.findRenderObject() as RenderBox;
        Offset local = box.globalToLocal(details.globalPosition);
        double cx = widget.size / 2, cy = widget.size / 2;
        double dx = local.dx - cx, dy = cy - local.dy;
        double max = widget.size / 2 - 28;
        double val = widget.isVertical
            ? (dy / max * 100).clamp(-100.0, 100.0)
            : (dx / max * 100).clamp(-100.0, 100.0);
        widget.onChanged(val);
      },
      onPanEnd: (_) => widget.onChanged(0.0),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0f172a), Color(0xFF1e293b)],
          ),
          border: Border.all(color: const Color(0xFF06B6D4).withOpacity(0.4), width: 2.5),
          boxShadow: [BoxShadow(
            color: const Color(0xFF164e63).withOpacity(0.5),
            blurRadius: 15, spreadRadius: 2,
          )],
        ),
        child: Stack(
          children: [
            if (widget.isVertical) ...[
              const Positioned(top: 8, left: 0, right: 0,
                  child: Icon(Icons.arrow_upward, color: Color(0xFF22D3EE), size: 16)),
              Positioned(bottom: 8, left: 0, right: 0,
                  child: Icon(Icons.arrow_downward,
                      color: const Color(0xFF22D3EE).withOpacity(0.5), size: 16)),
            ] else ...[
              Positioned(left: 8, top: 0, bottom: 0,
                  child: Icon(Icons.arrow_back,
                      color: const Color(0xFF22D3EE).withOpacity(0.5), size: 16)),
              const Positioned(right: 8, top: 0, bottom: 0,
                  child: Icon(Icons.arrow_forward, color: Color(0xFF22D3EE), size: 16)),
            ],
            Center(
              child: Transform.translate(
                offset: _knobOffset(),
                child: Container(
                  width: 46, height: 46,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF22D3EE), Color(0xFF3B82F6)],
                    ),
                    border: Border.all(color: const Color(0xFF67E8F9), width: 2),
                    boxShadow: [BoxShadow(
                      color: const Color(0xFF06B6D4).withOpacity(0.6),
                      blurRadius: 10, spreadRadius: 1,
                    )],
                  ),
                  child: Icon(widget.icon, color: Colors.white, size: 20),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Offset _knobOffset() {
    double max = 42.0, pct = widget.value / 100.0;
    return widget.isVertical ? Offset(0, -pct * max) : Offset(pct * max, 0);
  }
}