import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'api_exception.dart';


class ApiClient {
  ApiClient._();
  static final ApiClient instance = ApiClient._();

  String _baseUrl = '';
  String? _accessToken;

  // ─── Configuration ────────────────────────────────────────────

  void setBaseUrl(String url) {
    // Hapus trailing slash jika ada
    _baseUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  void setToken(String token) => _accessToken = token;
  void clearToken() => _accessToken = null;

  bool get isAuthenticated => _accessToken != null;
  String? get accessToken => _accessToken;

  /// Base URL untuk WebSocket: ganti http(s) → ws(s)
  String get wsBaseUrl {
    return _baseUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
  }

  // ─── Token Refresh ────────────────────────────────────────────

  /// Refresh Firebase token sebelum setiap request.
  /// Firebase ID token expired setiap 1 jam, jadi kita force refresh
  /// agar backend tidak reject dengan 401.
  Future<void> _refreshToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final token = await user.getIdToken(true); // force refresh
      if (token != null && token.isNotEmpty) {
        _accessToken = token;
      }
    }
  }

  // ─── Headers ──────────────────────────────────────────────────

  Map<String, String> _headers({bool requireAuth = true}) {
    final headers = {'Content-Type': 'application/json'};
    if (requireAuth && _accessToken != null) {
      headers['Authorization'] = 'Bearer $_accessToken';
    }
    return headers;
  }

  // ─── HTTP Methods ─────────────────────────────────────────────

  Future<Map<String, dynamic>> get(
    String path, {
    bool requireAuth = true,
  }) async {
    if (requireAuth) await _refreshToken();
    final uri = Uri.parse('$_baseUrl$path');
    final response = await http.get(uri, headers: _headers(requireAuth: requireAuth));
    return _handleResponse(response);
  }

  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    bool requireAuth = true,
  }) async {
    if (requireAuth) await _refreshToken();
    final uri = Uri.parse('$_baseUrl$path');
    final response = await http.post(
      uri,
      headers: _headers(requireAuth: requireAuth),
      body: body != null ? jsonEncode(body) : null,
    );
    return _handleResponse(response);
  }

  Future<Map<String, dynamic>> delete(
    String path, {
    bool requireAuth = true,
  }) async {
    if (requireAuth) await _refreshToken();
    final uri = Uri.parse('$_baseUrl$path');
    final response = await http.delete(uri, headers: _headers(requireAuth: requireAuth));
    return _handleResponse(response);
  }

  // ─── Response Handler ─────────────────────────────────────────

  Map<String, dynamic> _handleResponse(http.Response response) {
    final body = response.body;

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (body.isEmpty) return {};
      return jsonDecode(body) as Map<String, dynamic>;
    }

    // Coba parse error message dari JSON response
    String errorMessage = body;
    try {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      errorMessage = decoded['message'] ?? decoded['error'] ?? body;
    } catch (_) {
      // Bukan JSON, pakai raw body
    }

    throw ApiException.fromStatusCode(response.statusCode, errorMessage);
  }
}
