import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'login_page.dart';
import 'controller_page.dart';
import 'email_verification_page.dart';
import 'core/api_client.dart';
import 'core/firebase_config.dart';
import 'services/auth_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock landscape dari awal sebelum apapun tampil
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // Inisialisasi Firebase
  await FirebaseConfig.initialize();

  // Set base URL untuk REST API ke spedi-core backend
  ApiClient.instance.setBaseUrl(
    'https://spedi-core-production-8104.up.railway.app',
  );

  // Cek status login Firebase
  final authService = AuthService();
  final isLoggedIn = authService.isLoggedIn;
  final isEmailVerified = authService.isEmailVerified;
  final username = authService.currentUserEmail;

  // Restore token Firebase ke ApiClient hanya jika email sudah verified
  if (isLoggedIn && isEmailVerified) {
    await authService.restoreSession();
  }

  runApp(
    ShipControllerApp(
      isLoggedIn: isLoggedIn,
      isEmailVerified: isEmailVerified,
      username: username,
    ),
  );
}

class ShipControllerApp extends StatelessWidget {
  final bool isLoggedIn;
  final bool isEmailVerified;
  final String username;

  const ShipControllerApp({
    Key? key,
    required this.isLoggedIn,
    required this.isEmailVerified,
    required this.username,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SPEDI RC Controller',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: const Color(0xFF06B6D4),
        scaffoldBackgroundColor: const Color(0xFF020617),
      ),
      home: _getHomePage(),
    );
  }

  Widget _getHomePage() {
    if (!isLoggedIn) {
      // Belum login → halaman login
      return const LoginPage();
    }

    if (!isEmailVerified) {
      // Sudah login tapi email belum verified → halaman verifikasi
      return EmailVerificationPage(email: username);
    }

    // Sudah login dan email verified → controller
    return ShipControllerPage(username: username);
  }
}
