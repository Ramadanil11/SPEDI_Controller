import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Konfigurasi dan inisialisasi Supabase client.
/// Kredensial dibaca dari file .env agar tidak hardcode.
class SupabaseConfig {
  SupabaseConfig._();

  static String get supabaseUrl => dotenv.env['SUPABASE_URL']!;
  static String get supabaseAnonKey => dotenv.env['SUPABASE_ANON_KEY']!;
  static String get googleWebClientId => dotenv.env['GOOGLE_WEB_CLIENT_ID']!;

  /// Inisialisasi Supabase. Panggil sekali di main().
  static Future<void> initialize() async {
    await dotenv.load(fileName: '.env');

    final url = supabaseUrl;
    final key = supabaseAnonKey;
    final googleId = googleWebClientId;

    // Debug: verifikasi env variables ter-load dengan benar
    print('[SupabaseConfig] URL: $url');
    print('[SupabaseConfig] Anon Key (first 20): ${key.length >= 20 ? key.substring(0, 20) : key}...');
    print('[SupabaseConfig] Google Web Client ID: $googleId');

    await Supabase.initialize(
      url: url,
      anonKey: key,
    );
  }

  /// Shortcut ke Supabase client instance.
  static SupabaseClient get client => Supabase.instance.client;

  /// Shortcut ke Supabase auth instance.
  static GoTrueClient get auth => client.auth;

  /// Cek apakah user sedang login (ada session aktif).
  static bool get isLoggedIn => auth.currentSession != null;

  /// Ambil email user yang sedang login.
  static String get currentUserEmail =>
      auth.currentUser?.email ?? '';

  /// Ambil access token dari session aktif.
  static String get accessToken =>
      auth.currentSession?.accessToken ?? '';
}
