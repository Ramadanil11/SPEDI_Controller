import '../core/api_client.dart';

class ActiveSession {
  final String sessionId;
  final String deviceId;
  final String userId;
  final DateTime connectedAt;

  const ActiveSession({
    required this.sessionId,
    required this.deviceId,
    required this.userId,
    required this.connectedAt,
  });

  factory ActiveSession.fromJson(Map<String, dynamic> json) => ActiveSession(
        sessionId: json['sessionId'] as String,
        deviceId: json['deviceId'] as String,
        userId: json['userId'] as String,
        connectedAt: DateTime.parse(json['connectedAt'] as String),
      );
}

class SessionService {
  // ── Singleton ─────────────────────────────────────────────────────────────
  SessionService._();
  static final SessionService instance = SessionService._();
  factory SessionService() => instance;

  final _client = ApiClient.instance;

  bool _hasSession = false;
  bool get hasSession => _hasSession;

  Future<ActiveSession> openSession(String deviceId) async {
    // Jika sudah ada session aktif, coba ambil dulu sebelum buat baru
    if (_hasSession) {
      try {
        final existing = await getCurrentSession();
        if (existing != null) return existing;
      } catch (_) {
        // Session hilang di server, lanjut buat baru
      }
    }

    final data = await _client.post(
      '/session',
      body: {'device_id': deviceId},
    );
    _hasSession = true;
    return ActiveSession.fromJson(data);
  }

  Future<ActiveSession?> getCurrentSession() async {
    final data = await _client.get('/session');
    if (data.isEmpty || data['sessionId'] == null) {
      _hasSession = false;
      return null;
    }
    _hasSession = true;
    return ActiveSession.fromJson(data);
  }

  Future<void> closeSession() async {
    if (!_hasSession) return;
    try {
      await _client.delete('/session');
    } catch (_) {
      // Abaikan error saat close — mungkin sudah expired
    }
    _hasSession = false;
  }
}