import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class MqttDeviceService {
  // ── Singleton ─────────────────────────────────────────────────────────────
  MqttDeviceService._();
  static final MqttDeviceService instance = MqttDeviceService._();
  factory MqttDeviceService() => instance;

  static const _host = 'metro.proxy.rlwy.net';
  static const _port = 41220;
  static const _username = 'device';
  static const _password = 'spedi2026';
  static const _topicStatus   = 'spedi/vehicle/status';
  static const _topicNavEvent = 'spedi/vehicle/nav_event';

  /// Client ID unik — mencegah broker kick saat reconnect
  static String _generateClientId() {
    final rng = math.Random();
    final suffix = rng.nextInt(0xFFFF).toRadixString(16).padLeft(4, '0');
    return 'spedi-app-$suffix';
  }

  MqttServerClient? _client;
  bool _isRunning = false;
  bool get isRunning => _isRunning;

  bool _disposed = false;

  // ─── GPS Arduino (dari telemetri MQTT) ────────────────────────────────────
  double arduinoLat      = 0.0;
  double arduinoLng      = 0.0;
  double arduinoBearing  = 0.0;
  double arduinoSpeed    = 0.0;
  double arduinoHdop     = 99.9;
  bool   gpsFix          = false;
  int    gpsQuality      = 0;
  int    satelliteCount  = 0;
  bool   locationLoaded  = false;

  // ─── Telemetri tambahan dari Arduino v14.5-S3 ─────────────────────────────
  String deviceMode       = 'idle';       // idle | manual | auto
  int    motorSpeed       = 0;            // -255..255
  int    waypointIndex    = 0;            // indeks waypoint aktif
  bool   autopilotActive  = false;        // true saat mode auto berjalan
  bool   smartMoveActive  = false;        // true saat obstacle avoidance aktif
  int    obstacleLeft     = 400;          // jarak sonar kiri (cm)
  int    obstacleRight    = 400;          // jarak sonar kanan (cm)
  double steerIntegral    = 0.0;          // akumulator PI steering
  double lastHeading      = 0.0;          // heading terakhir valid (derajat)

  // ─── Telemetri baru dari Arduino v14.8-S3 (Navigation Grid) ──────────────
  int    waypointCount    = 0;            // total waypoint menurut Arduino
  bool   headingValid     = false;        // false jika heading stale >10 detik
  bool   motorDisabled    = false;        // true setelah emergency stop
  int    uptimeS          = 0;            // uptime Arduino dalam detik
  double xte              = 0.0;          // cross-track error (meter)
  double arrivalRadius    = 3.0;          // dynamic arrival radius (meter)
  int    wpElapsedS       = 0;            // detik sejak mulai menuju WP aktif
  int    wpTimeoutS       = 120;          // batas timeout per-WP (detik)
  double wpDistM          = 0.0;          // jarak ke WP aktif (meter)

  // ─── Telemetri baru dari Arduino v15.0-S3 (GSM + M8U Sensor Fusion) ─────
  bool   gsmConnected     = false;          // status koneksi GSM 4G
  int    signalQuality    = 0;              // CSQ signal (0-31)
  double drHeading        = 0.0;            // heading dari IMU/DR (derajat)
  double drHeadingAcc     = 999.0;          // heading accuracy (derajat)
  bool   drValid          = false;          // apakah DR heading valid
  int    fusionMode       = 0;              // 0=init, 1=calib, 2=fused, 3=DR

  // ─── Navigation event stream (dari topic nav_event) ──────────────────────
  final _navEventController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get navEventStream => _navEventController.stream;

  // Notifier untuk update UI secara reaktif
  final ValueNotifier<Map<String, dynamic>> telemetryNotifier =
      ValueNotifier({});

  final _statusController  = StreamController<String>.broadcast();
  Stream<String> get statusStream  => _statusController.stream;

  final _runningController = StreamController<bool>.broadcast();
  Stream<bool>   get runningStream => _runningController.stream;

  // ─── Auto-reconnect state ─────────────────────────────────────────────────
  Timer? _reconnectTimer;
  int    _reconnectAttempt = 0;
  static const _maxReconnectDelay = 30; // detik

  /// Dipanggil tanpa await — tidak blocking UI
  void startAsync() {
    _disposed = false;
    unawaited(_doStart());
  }

  Future<void> _doStart() async {
    if (_isRunning || _disposed) return;

    final clientId = _generateClientId();

    _client = MqttServerClient.withPort(_host, clientId, _port);
    _client!.logging(on: false);
    _client!.keepAlivePeriod = 30;
    _client!.connectTimeoutPeriod = 15000;  // 15 detik timeout
    _client!.onDisconnected = _onDisconnected;
    _client!.onConnected = _onConnected;
    _client!.onSubscribed = (topic) => _log('📡 Subscribed: $topic');

    // Auto-reconnect bawaan mqtt_client
    _client!.autoReconnect = true;
    _client!.onAutoReconnect = _onAutoReconnect;
    _client!.onAutoReconnected = _onAutoReconnected;

    final connMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .authenticateAs(_username, _password)
        .withWillQos(MqttQos.atLeastOnce)
        .startClean();
    _client!.connectionMessage = connMessage;

    try {
      _log('🔌 Menghubungkan ke MQTT ($clientId)...');
      await _client!.connect(_username, _password);
    } catch (e) {
      _log('❌ Gagal connect MQTT: $e');
      _client?.disconnect();
      _client = null;
      _scheduleReconnect();
      return;
    }

    if (_client?.connectionStatus?.state != MqttConnectionState.connected) {
      _log('❌ MQTT ditolak: ${_client?.connectionStatus?.returnCode}');
      _client?.disconnect();
      _client = null;
      _scheduleReconnect();
      return;
    }

    _onConnectionSuccess();
  }

  void _onConnectionSuccess() {
    _log('✅ MQTT terhubung! Menunggu GPS Arduino...');
    _isRunning = true;
    _reconnectAttempt = 0;
    _runningController.add(true);

    // Subscribe ke topic telemetri Arduino + navigation events
    _client!.subscribe(_topicStatus, MqttQos.atLeastOnce);
    _client!.subscribe(_topicNavEvent, MqttQos.atLeastOnce);

    // Listen pesan masuk dari Arduino
    _client!.updates?.listen((List<MqttReceivedMessage<MqttMessage>> messages) {
      for (final msg in messages) {
        final recMess = msg.payload as MqttPublishMessage;
        final payload = MqttPublishPayload.bytesToStringAsString(
            recMess.payload.message);
        if (msg.topic == _topicStatus) {
          _handleTelemetry(payload);
        } else if (msg.topic == _topicNavEvent) {
          _handleNavEvent(payload);
        }
      }
    });
  }

  // ─── Auto-reconnect callbacks ─────────────────────────────────────────────

  void _onConnected() {
    _log('🟢 MQTT onConnected');
  }

  void _onAutoReconnect() {
    _log('🔄 MQTT auto-reconnecting...');
    _isRunning = false;
    _runningController.add(false);
  }

  void _onAutoReconnected() {
    _log('✅ MQTT auto-reconnected!');
    _isRunning = true;
    _reconnectAttempt = 0;
    _runningController.add(true);
  }

  /// Fallback reconnect jika koneksi awal gagal total (bukan auto-reconnect).
  /// Exponential backoff: 2s, 4s, 8s, 16s, 30s max.
  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();

    final delay = math.min(
      (math.pow(2, _reconnectAttempt) * 2).toInt(),
      _maxReconnectDelay,
    );
    _reconnectAttempt++;

    _log('⏳ Reconnect dalam ${delay}s (attempt #$_reconnectAttempt)...');
    _reconnectTimer = Timer(Duration(seconds: delay), () {
      if (!_disposed) _doStart();
    });
  }

  void _handleTelemetry(String raw) {
    try {
      final Map<String, dynamic> data = jsonDecode(raw);

      // ── GPS dasar ──────────────────────────────────────────────────────
      arduinoLat     = (data['lat']              ?? 0.0).toDouble();
      arduinoLng     = (data['lng']              ?? 0.0).toDouble();
      arduinoBearing = (data['bearing']          ?? 0.0).toDouble();
      arduinoSpeed   = (data['speed']            ?? 0.0).toDouble();
      arduinoHdop    = (data['hdop']             ?? 99.9).toDouble();
      gpsFix         =  data['gps_fix']          ?? false;
      gpsQuality     = (data['gps_quality']      ?? 0);
      satelliteCount = (data['satellite_count']  ?? 0);

      // ── Telemetri tambahan v14.5-S3 ───────────────────────────────────
      deviceMode      = (data['mode']              ?? 'idle').toString();
      motorSpeed      = _toInt(data['motor_speed'],    0);
      waypointIndex   = _toInt(data['waypoint_index'], 0);
      autopilotActive =  data['autopilot_active']  ?? false;
      smartMoveActive =  data['smart_move_active'] ?? false;
      obstacleLeft    = _toInt(data['obstacle_left'],  400);
      obstacleRight   = _toInt(data['obstacle_right'], 400);
      steerIntegral   = (data['steer_integral']    ?? 0.0).toDouble();
      lastHeading     = (data['last_heading']      ?? 0.0).toDouble();

      // ── Telemetri baru v14.8-S3 (Navigation Grid) ────────────────────
      waypointCount   = _toInt(data['waypoint_count'],  0);
      headingValid    =  data['heading_valid']     ?? true;
      motorDisabled   =  data['motor_disabled']    ?? false;
      uptimeS         = _toInt(data['uptime_s'],        0);
      xte             = (data['xte']               ?? 0.0).toDouble();
      arrivalRadius   = (data['arrival_radius']    ?? 3.0).toDouble();
      wpElapsedS      = _toInt(data['wp_elapsed_s'],    0);
      wpTimeoutS      = _toInt(data['wp_timeout_s'],  120);
      wpDistM         = (data['wp_dist_m']         ?? 0.0).toDouble();

      // ── Telemetri baru v15.0-S3 (GSM + M8U Sensor Fusion) ────────────
      gsmConnected    =  data['gsm_connected']     ?? false;
      signalQuality   = _toInt(data['signal_quality'],    0);
      drHeading       = (data['dr_heading']        ?? 0.0).toDouble();
      drHeadingAcc    = (data['dr_heading_acc']    ?? 999.0).toDouble();
      drValid         =  data['dr_valid']          ?? false;
      fusionMode      = _toInt(data['fusion_mode'],        0);

      if (gpsFix && arduinoLat != 0.0 && arduinoLng != 0.0) {
        locationLoaded = true;
      }

      telemetryNotifier.value = Map<String, dynamic>.from(data);

      _log('📍 Arduino GPS: ${arduinoLat.toStringAsFixed(5)}, '
          '${arduinoLng.toStringAsFixed(5)} | '
          'spd: ${arduinoSpeed.toStringAsFixed(1)} km/h | '
          'sat: $satelliteCount | fix: $gpsFix | '
          'mode: $deviceMode');
    } catch (e) {
      _log('⚠️ Gagal parse telemetri: $e');
    }
  }

  void _handleNavEvent(String raw) {
    try {
      final Map<String, dynamic> data = jsonDecode(raw);
      final event = (data['event'] ?? '').toString();
      _log('🚩 Nav event: $event | WP:${data['wp_index']} | dist:${data['dist_m']}');
      if (!_navEventController.isClosed) {
        _navEventController.add(Map<String, dynamic>.from(data));
      }
    } catch (e) {
      _log('⚠️ Gagal parse nav event: $e');
    }
  }

  /// Helper: konversi dynamic ke int dengan fallback
  int _toInt(dynamic v, int fallback) {
    if (v == null) return fallback;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return fallback;
  }

  Future<void> stop() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _client?.autoReconnect = false;
    _client?.disconnect();
    _client = null;
    _isRunning = false;
    _runningController.add(false);
    _log('🛑 MQTT device service dihentikan');
  }

  void _onDisconnected() {
    _log('🔴 MQTT terputus');
    _isRunning = false;
    _runningController.add(false);

    // Jika bukan karena dispose, coba reconnect manual sebagai fallback
    if (!_disposed && _client?.autoReconnect != true) {
      _scheduleReconnect();
    }
  }

  void _log(String message) {
    debugPrint('[MQTT] $message');
    if (!_statusController.isClosed) {
      _statusController.add(message);
    }
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    stop();
    telemetryNotifier.dispose();
    _statusController.close();
    _runningController.close();
    _navEventController.close();
  }
}
