import 'dart:async';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../core/api_client.dart';

enum WsConnectionState { disconnected, connecting, connected, error }

class WebSocketService {
  // ── Singleton ─────────────────────────────────────────────────────────────
  WebSocketService._();
  static final WebSocketService instance = WebSocketService._();
  factory WebSocketService() => instance;

  final _client = ApiClient.instance;
  final _firebaseAuth = FirebaseAuth.instance;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;

  WsConnectionState _state = WsConnectionState.disconnected;
  WsConnectionState get state => _state;

  final _stateController = StreamController<WsConnectionState>.broadcast();
  Stream<WsConnectionState> get stateStream => _stateController.stream;

  final _errorController = StreamController<String>.broadcast();
  Stream<String> get errorStream => _errorController.stream;

  bool _intentionalDisconnect = false;
  Timer? _reconnectTimer;

  Future<void> connect() async {
    if (_state == WsConnectionState.connected && _channel != null) return;

    _intentionalDisconnect = false;

    // Refresh Firebase token sebelum connect WebSocket
    await _refreshFirebaseToken();

    if (!ApiClient.instance.isAuthenticated) {
      debugPrint('[WS] Tidak authenticated — skip connect');
      return;
    }

    final token = _extractToken();
    final wsUrl = '${_client.wsBaseUrl}/control?token=$token';
    debugPrint('[WS] Connecting to: $wsUrl');

    _setState(WsConnectionState.connecting);

    try {
      // Bersihkan koneksi lama jika ada
      await _subscription?.cancel();
      _subscription = null;
      try { await _channel?.sink.close(); } catch (_) {}
      _channel = null;

      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      await _channel!.ready;
      _setState(WsConnectionState.connected);
      debugPrint('[WS] Connected');

      _subscription = _channel!.stream.listen(
        (_) {},
        onError: (error) {
          debugPrint('[WS] Stream error: $error');
          _errorController.add(error.toString());
          _setState(WsConnectionState.error);
          _scheduleReconnect();
        },
        onDone: () {
          debugPrint('[WS] Stream closed');
          _setState(WsConnectionState.disconnected);
          if (!_intentionalDisconnect) {
            _scheduleReconnect();
          }
        },
      );
    } catch (e) {
      _setState(WsConnectionState.error);
      debugPrint('[WS] Connect error: $e');
      _errorController.add('Failed to connect: $e');
      _scheduleReconnect();
    }
  }

  /// Auto-reconnect setelah 3 detik jika bukan disconnect sengaja
  void _scheduleReconnect() {
    if (_intentionalDisconnect) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (_state != WsConnectionState.connected && !_intentionalDisconnect) {
        debugPrint('[WS] Auto-reconnecting...');
        connect();
      }
    });
  }

  void sendJoystick({required int throttle, required int steering}) {
    if (_state != WsConnectionState.connected || _channel == null) {
      debugPrint('[WS] sendJoystick skipped — state: $_state');
      return;
    }

    final frame = jsonEncode({
      'type': 'joystick',
      'payload': {
        'throttle': throttle.clamp(-100, 100),
        'steering': steering.clamp(-100, 100),
      },
    });

    try {
      _channel!.sink.add(frame);
    } catch (e) {
      debugPrint('[WS] Send error: $e');
      _setState(WsConnectionState.error);
      _scheduleReconnect();
    }
  }

  void sendStop() => sendJoystick(throttle: 0, steering: 0);

  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    try { await _channel?.sink.close(); } catch (_) {}
    _channel = null;
    _setState(WsConnectionState.disconnected);
  }

  void dispose() {
    disconnect();
    _stateController.close();
    _errorController.close();
  }

  void _setState(WsConnectionState newState) {
    _state = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  String _extractToken() {
    return ApiClient.instance.accessToken!;
  }

  /// Refresh Firebase token agar WebSocket tidak 401.
  Future<void> _refreshFirebaseToken() async {
    try {
      final user = _firebaseAuth.currentUser;
      if (user != null) {
        final token = await user.getIdToken(true);
        if (token != null && token.isNotEmpty) {
          ApiClient.instance.setToken(token);
        }
      }
    } catch (e) {
      debugPrint('[WS] Gagal refresh token: $e');
    }
  }
}
