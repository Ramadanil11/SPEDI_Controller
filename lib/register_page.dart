import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'controller_page.dart';
import 'email_verification_page.dart';
import 'services/auth_service.dart';


class RegisterPage extends StatefulWidget {
  const RegisterPage({Key? key}) : super(key: key);

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();
  bool _isPasswordVisible = false;
  bool _isConfirmPasswordVisible = false;
  bool _isLoading = false;
  bool _isGoogleLoading = false;

  void _handleRegister() async {
    if (_emailController.text.isEmpty ||
        _passwordController.text.isEmpty ||
        _confirmPasswordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Mohon isi semua field'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (_passwordController.text != _confirmPasswordController.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Password tidak cocok'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (_passwordController.text.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Password minimal 6 karakter'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    await Future.delayed(const Duration(milliseconds: 100));

    try {
      await AuthService().register(
        _emailController.text.trim(),
        _passwordController.text,
      );

      if (!mounted) return;

      // Register berhasil → arahkan ke halaman verifikasi email
      // User TETAP signed in agar bisa reload() dan kirim ulang verifikasi
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Link verifikasi telah dikirim ke email Anda. Cek inbox/spam.'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 4),
        ),
      );

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => EmailVerificationPage(
              email: _emailController.text.trim(),
            ),
          ),
        );
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        String displayMessage;
        switch (e.code) {
          case 'email-already-in-use':
            displayMessage =
                'Email sudah terdaftar. Silakan login dengan password Anda.';
            break;
          case 'invalid-email':
            displayMessage = 'Format email tidak valid.';
            break;
          case 'weak-password':
            displayMessage = 'Password terlalu lemah. Gunakan minimal 6 karakter.';
            break;
          case 'operation-not-allowed':
            displayMessage = 'Registrasi email/password belum diaktifkan.';
            break;
          default:
            displayMessage = e.message ?? 'Registrasi gagal';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(displayMessage),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        debugPrint('[Register] Error: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Register gagal: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _handleGoogleSignUp() async {
    setState(() => _isGoogleLoading = true);

    try {
      final credential = await AuthService().signInWithGoogle();

      final email = credential.user?.email ?? '';

      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (context) => ShipControllerPage(username: email),
          ),
          (route) => false,
        );
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message ?? 'Google Sign-In gagal'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        final msg = e.toString();
        if (!msg.contains('dibatalkan')) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Google Sign-In gagal: $msg'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _isGoogleLoading = false);
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final bool anyLoading = _isLoading || _isGoogleLoading;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF020617), Color(0xFF172554), Color(0xFF0f172a)],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight:
                    mq.size.height - mq.padding.top - mq.padding.bottom - 16,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // ── Kiri: Logo ────────────────────────────────────────
                  Expanded(
                    flex: 4,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF06B6D4).withOpacity(0.1),
                            border: Border.all(
                                color:
                                    const Color(0xFF06B6D4).withOpacity(0.3),
                                width: 2),
                            boxShadow: [
                              BoxShadow(
                                  color: const Color(0xFF06B6D4)
                                      .withOpacity(0.3),
                                  blurRadius: 20,
                                  spreadRadius: 3)
                            ],
                          ),
                          child: const Icon(Icons.person_add_outlined,
                              size: 40, color: Color(0xFF22D3EE)),
                        ),
                        const SizedBox(height: 10),
                        Text('DAFTAR',
                            style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFFE0F2FE),
                                letterSpacing: 6,
                                shadows: [
                                  Shadow(
                                      color: const Color(0xFF06B6D4)
                                          .withOpacity(0.5),
                                      blurRadius: 20)
                                ])),
                        const SizedBox(height: 4),
                        Text('AKUN BARU',
                            style: TextStyle(
                                fontSize: 11,
                                color:
                                    const Color(0xFF22D3EE).withOpacity(0.7),
                                letterSpacing: 4,
                                fontWeight: FontWeight.w300)),
                      ],
                    ),
                  ),
                  Container(
                      width: 1,
                      height: 220,
                      color: const Color(0xFF06B6D4).withOpacity(0.2)),
                  // ── Kanan: Form ───────────────────────────────────────
                  Expanded(
                    flex: 5,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 8),
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 380),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                              color:
                                  const Color(0xFF06B6D4).withOpacity(0.3),
                              width: 2),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Email field
                            const Text('EMAIL',
                                style: TextStyle(
                                    color: Color(0xFF22D3EE),
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.5)),
                            const SizedBox(height: 6),
                            _buildTextField(
                              controller: _emailController,
                              icon: Icons.email_outlined,
                              hint: 'Masukkan email',
                              enabled: !anyLoading,
                              keyboardType: TextInputType.emailAddress,
                            ),
                            const SizedBox(height: 10),

                            // Password field
                            const Text('PASSWORD',
                                style: TextStyle(
                                    color: Color(0xFF22D3EE),
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.5)),
                            const SizedBox(height: 6),
                            _buildTextField(
                              controller: _passwordController,
                              icon: Icons.lock_outline,
                              hint: 'Masukkan password',
                              enabled: !anyLoading,
                              isPassword: true,
                              isPasswordVisible: _isPasswordVisible,
                              onTogglePassword: () => setState(
                                  () => _isPasswordVisible = !_isPasswordVisible),
                            ),
                            const SizedBox(height: 10),

                            // Confirm password field
                            const Text('KONFIRMASI PASSWORD',
                                style: TextStyle(
                                    color: Color(0xFF22D3EE),
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.5)),
                            const SizedBox(height: 6),
                            _buildTextField(
                              controller: _confirmPasswordController,
                              icon: Icons.lock_outline,
                              hint: 'Konfirmasi password',
                              enabled: !anyLoading,
                              isPassword: true,
                              isPasswordVisible: _isConfirmPasswordVisible,
                              onTogglePassword: () => setState(() =>
                                  _isConfirmPasswordVisible =
                                      !_isConfirmPasswordVisible),
                              onSubmitted: (_) => _handleRegister(),
                            ),
                            const SizedBox(height: 14),

                            // Tombol Register
                            ElevatedButton(
                              onPressed: anyLoading ? null : _handleRegister,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF06B6D4),
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                                elevation: 0,
                              ),
                              child: _isLoading
                                  ? const SizedBox(
                                      height: 18,
                                      width: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                  Colors.white)))
                                  : const Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                          Icon(Icons.how_to_reg, size: 18),
                                          SizedBox(width: 8),
                                          Text('DAFTAR',
                                              style: TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.bold,
                                                  letterSpacing: 2))
                                        ]),
                            ),
                            const SizedBox(height: 10),

                            // ── Divider "atau" ──────────────────────────
                            Row(
                              children: [
                                Expanded(
                                  child: Container(
                                    height: 1,
                                    color: const Color(0xFF06B6D4)
                                        .withOpacity(0.2),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12),
                                  child: Text(
                                    'ATAU',
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.4),
                                      fontSize: 10,
                                      letterSpacing: 2,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Container(
                                    height: 1,
                                    color: const Color(0xFF06B6D4)
                                        .withOpacity(0.2),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),

                            // ── Tombol Google Sign-Up ───────────────────
                            OutlinedButton(
                              onPressed:
                                  anyLoading ? null : _handleGoogleSignUp,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: BorderSide(
                                  color: const Color(0xFF06B6D4)
                                      .withOpacity(0.5),
                                ),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 11),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                              child: _isGoogleLoading
                                  ? const SizedBox(
                                      height: 18,
                                      width: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                                Color(0xFF22D3EE)),
                                      ),
                                    )
                                  : Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Container(
                                          width: 20,
                                          height: 20,
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius:
                                                BorderRadius.circular(4),
                                          ),
                                          child: const Center(
                                            child: Text(
                                              'G',
                                              style: TextStyle(
                                                color: Color(0xFF4285F4),
                                                fontSize: 14,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        const Text(
                                          'DAFTAR DENGAN GOOGLE',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            letterSpacing: 1.5,
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                            const SizedBox(height: 10),

                            // ── Link ke Login ───────────────────────────
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  'Sudah punya akun? ',
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.4),
                                    fontSize: 11,
                                  ),
                                ),
                                GestureDetector(
                                  onTap: anyLoading
                                      ? null
                                      : () => Navigator.of(context).pop(),
                                  child: const Text(
                                    'Login di sini',
                                    style: TextStyle(
                                      color: Color(0xFF22D3EE),
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required IconData icon,
    required String hint,
    bool enabled = true,
    bool isPassword = false,
    bool isPasswordVisible = false,
    VoidCallback? onTogglePassword,
    TextInputType? keyboardType,
    Function(String)? onSubmitted,
  }) {
    return TextField(
      controller: controller,
      obscureText: isPassword && !isPasswordVisible,
      enabled: enabled,
      keyboardType: keyboardType,
      onSubmitted: onSubmitted,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        filled: true,
        fillColor: Colors.black.withOpacity(0.3),
        prefixIcon: Icon(icon, color: const Color(0xFF22D3EE), size: 18),
        suffixIcon: isPassword
            ? IconButton(
                icon: Icon(
                    isPasswordVisible
                        ? Icons.visibility_off
                        : Icons.visibility,
                    color: const Color(0xFF22D3EE),
                    size: 18),
                onPressed: onTogglePassword,
              )
            : null,
        hintText: hint,
        hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
        contentPadding:
            const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
                color: const Color(0xFF06B6D4).withOpacity(0.3))),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
                color: const Color(0xFF06B6D4).withOpacity(0.3))),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide:
                const BorderSide(color: Color(0xFF06B6D4), width: 2)),
      ),
    );
  }
}
