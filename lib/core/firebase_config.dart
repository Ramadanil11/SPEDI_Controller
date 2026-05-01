import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Konfigurasi dan inisialisasi Firebase.
/// Kredensial dibaca otomatis dari google-services.json (Android)
/// yang di-generate oleh FlutterFire CLI.
class FirebaseConfig {
  FirebaseConfig._();

  /// Inisialisasi Firebase. Panggil sekali di main().
  static Future<void> initialize() async {
    await Firebase.initializeApp();
  }

  /// Shortcut ke Firebase Auth instance.
  static FirebaseAuth get auth => FirebaseAuth.instance;

  /// Cek apakah user sedang login (ada session aktif).
  static bool get isLoggedIn => auth.currentUser != null;

  /// Ambil email user yang sedang login.
  static String get currentUserEmail =>
      auth.currentUser?.email ?? '';

  /// Ambil access token dari session aktif.
  static Future<String> getAccessToken() async {
    final user = auth.currentUser;
    if (user == null) return '';
    final token = await user.getIdToken();
    return token ?? '';
  }
}
