import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../core/firebase_config.dart';
import '../core/api_client.dart';

/// Service untuk autentikasi menggunakan Firebase.
///
/// Mendukung:
/// - Login/Register via email + password
/// - Login/Register via Google Sign-In
/// - Email verification (kirim link verifikasi)
/// - Session management (auto-persist oleh Firebase SDK)
class AuthService {
  final FirebaseAuth _auth = FirebaseConfig.auth;
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: ['email'],
    serverClientId: '364043931191-2p9jnfb315qltiaq10los8fp6n886e8t.apps.googleusercontent.com',
  );

  // ── Email + Password ────────────────────────────────────────────

  /// Login dengan email + password via Firebase.
  Future<UserCredential> login(String email, String password) async {
    final credential = await _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
    await _syncTokenToApiClient();
    return credential;
  }

  /// Register akun baru via email + password.
  /// Firebase akan membuat akun dan kita kirim email verifikasi.
  /// User TETAP signed in agar bisa reload() dan cek emailVerified.
  Future<UserCredential> register(String email, String password) async {
    final credential = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    // Kirim email verifikasi
    await credential.user?.sendEmailVerification();
    // JANGAN sign out — user harus tetap login agar bisa:
    // 1. reload() untuk cek emailVerified
    // 2. sendEmailVerification() untuk kirim ulang
    return credential;
  }

  /// Login dengan pengecekan apakah email sudah diverifikasi.
  ///
  /// Throws [UnverifiedEmailException] jika email belum verified.
  /// User TETAP signed in agar halaman verifikasi bisa bekerja.
  Future<UserCredential> loginWithVerificationCheck(
      String email, String password) async {
    final credential = await _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );

    final user = credential.user;
    if (user != null && !user.emailVerified) {
      // Kirim ulang email verifikasi
      await user.sendEmailVerification();
      // JANGAN sign out — biarkan user tetap login
      // agar halaman verifikasi bisa reload() dan cek status
      throw UnverifiedEmailException(
        'Email belum diverifikasi. Link verifikasi baru telah dikirim ke $email. Cek inbox/spam Anda.',
        email: email,
      );
    }

    // Email sudah verified → sync token ke ApiClient
    await _syncTokenToApiClient();
    return credential;
  }

  /// Kirim ulang email verifikasi untuk user yang sedang login.
  Future<void> resendVerificationEmail() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Tidak ada user yang login. Silakan login ulang.');
    }
    await user.sendEmailVerification();
  }

  /// Cek apakah email sudah diverifikasi.
  /// Reload user data dari Firebase untuk mendapatkan status terbaru.
  Future<bool> checkEmailVerified() async {
    final user = _auth.currentUser;
    if (user == null) return false;
    await user.reload();
    final refreshedUser = _auth.currentUser;
    return refreshedUser?.emailVerified ?? false;
  }

  // ── Google Sign-In ──────────────────────────────────────────────

  /// Login atau register menggunakan akun Google.
  /// Google Sign-In otomatis verified, tidak perlu verifikasi email.
  Future<UserCredential> signInWithGoogle() async {
    final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();

    if (googleUser == null) {
      throw Exception('Google Sign-In dibatalkan oleh user');
    }

    final GoogleSignInAuthentication googleAuth =
        await googleUser.authentication;

    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    final userCredential = await _auth.signInWithCredential(credential);
    await _syncTokenToApiClient();
    return userCredential;
  }

  // ── Session Management ──────────────────────────────────────────

  /// Cek apakah ada user yang login.
  bool get isLoggedIn => _auth.currentUser != null;

  /// Cek apakah user yang login sudah verifikasi email.
  bool get isEmailVerified => _auth.currentUser?.emailVerified ?? false;

  /// Ambil email user yang sedang login.
  String get currentUserEmail => _auth.currentUser?.email ?? '';

  /// Ambil access token dari user aktif (force refresh).
  Future<String> getAccessToken({bool forceRefresh = false}) async {
    final user = _auth.currentUser;
    if (user == null) return '';
    final token = await user.getIdToken(forceRefresh);
    return token ?? '';
  }

  /// Sinkronkan token Firebase ke ApiClient (untuk REST API ke spedi-core).
  /// Force refresh agar token selalu fresh.
  Future<void> _syncTokenToApiClient() async {
    final token = await getAccessToken(forceRefresh: true);
    if (token.isNotEmpty) {
      ApiClient.instance.setToken(token);
    }
  }

  /// Restore session saat app startup.
  /// Firebase SDK otomatis menyimpan session, tapi kita perlu
  /// sinkronkan token ke ApiClient.
  Future<void> restoreSession() async {
    await _syncTokenToApiClient();
  }

  /// Logout: sign out dari Firebase + Google.
  Future<void> logout() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
    await _auth.signOut();
    ApiClient.instance.clearToken();
  }
}

/// Exception khusus ketika login gagal karena email belum diverifikasi.
class UnverifiedEmailException implements Exception {
  final String message;
  final String email;

  UnverifiedEmailException(this.message, {required this.email});

  @override
  String toString() => message;
}
