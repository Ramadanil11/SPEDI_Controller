import 'dart:async';
import 'package:flutter/material.dart';
import 'controller_page.dart';
import 'login_page.dart';
import 'services/auth_service.dart';

/// Halaman verifikasi email setelah register via Firebase.
///
/// Firebase mengirim LINK verifikasi ke email (bukan OTP).
/// User harus klik link di email, lalu kembali ke app.
/// App auto-check setiap 3 detik apakah email sudah verified.
class EmailVerificationPage extends StatefulWidget {
  final String email;

  const EmailVerificationPage({Key? key, required this.email}) : super(key: key);

  @override
  State<EmailVerificationPage> createState() => _EmailVerificationPageState();
}

class _EmailVerificationPageState extends State<EmailVerificationPage>
    with WidgetsBindingObserver {
  final _authService = AuthService();
  bool _isChecking = false;
  bool _isResending = false;
  int _resendCooldown = 0;
  Timer? _cooldownTimer;
  Timer? _autoCheckTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startResendCooldown();
    // Auto-check setiap 3 detik
    _autoCheckTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _checkVerification(silent: true);
    });
  }

  /// Saat user kembali ke app (setelah klik link di browser),
  /// langsung cek verifikasi.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkVerification(silent: false);
    }
  }

  void _startResendCooldown() {
    setState(() => _resendCooldown = 30);
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_resendCooldown <= 0) {
        timer.cancel();
      } else {
        if (mounted) setState(() => _resendCooldown--);
      }
    });
  }

  void _checkVerification({bool silent = false}) async {
    if (_isChecking) return;

    if (!silent && mounted) {
      setState(() => _isChecking = true);
    }

    try {
      final isVerified = await _authService.checkEmailVerified();

      if (isVerified) {
        // Email sudah diverifikasi! Sync token dan masuk controller.
        await _authService.restoreSession();

        if (mounted) {
          _autoCheckTimer?.cancel();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Email berhasil diverifikasi!'),
              backgroundColor: Colors.green,
            ),
          );

          final email = _authService.currentUserEmail.isNotEmpty
              ? _authService.currentUserEmail
              : widget.email;

          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (context) => ShipControllerPage(username: email),
            ),
            (route) => false,
          );
        }
        return;
      }

      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Email belum diverifikasi. Cek inbox/spam Anda dan klik link verifikasi.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      if (!silent && mounted) {
        debugPrint('[Verify Check] Error: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal cek verifikasi: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted && !silent) setState(() => _isChecking = false);
    }
  }

  void _handleResend() async {
    if (_resendCooldown > 0 || _isResending) return;

    setState(() => _isResending = true);

    try {
      await _authService.resendVerificationEmail();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Link verifikasi baru telah dikirim ke email Anda'),
            backgroundColor: Colors.green,
          ),
        );
        _startResendCooldown();
      }
    } catch (e) {
      if (mounted) {
        final msg = e.toString().toLowerCase();
        if (msg.contains('too-many-requests') || msg.contains('too many')) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Terlalu sering mengirim. Tunggu beberapa menit.'),
              backgroundColor: Colors.orange,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Gagal kirim ulang: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _isResending = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cooldownTimer?.cancel();
    _autoCheckTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
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
                  // ── Kiri: Ikon email ──────────────────────────────────
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
                              color: const Color(0xFF06B6D4).withOpacity(0.3),
                              width: 2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF06B6D4).withOpacity(0.3),
                                blurRadius: 20,
                                spreadRadius: 3,
                              ),
                            ],
                          ),
                          child: const Icon(Icons.mark_email_read_outlined,
                              size: 40, color: Color(0xFF22D3EE)),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'VERIFIKASI',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFFE0F2FE),
                            letterSpacing: 6,
                            shadows: [
                              Shadow(
                                color:
                                    const Color(0xFF06B6D4).withOpacity(0.5),
                                blurRadius: 20,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'EMAIL',
                          style: TextStyle(
                            fontSize: 11,
                            color: const Color(0xFF22D3EE).withOpacity(0.7),
                            letterSpacing: 4,
                            fontWeight: FontWeight.w300,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 1,
                    height: 180,
                    color: const Color(0xFF06B6D4).withOpacity(0.2),
                  ),
                  // ── Kanan: Instruksi ─────────────────────────────────
                  Expanded(
                    flex: 5,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 8),
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 400),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: const Color(0xFF06B6D4).withOpacity(0.3),
                            width: 2,
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Link verifikasi telah dikirim ke:',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.7),
                                fontSize: 12,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              widget.email,
                              style: const TextStyle(
                                color: Color(0xFF22D3EE),
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 2,
                            ),
                            const SizedBox(height: 16),

                            // Instruksi
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF06B6D4).withOpacity(0.1),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: const Color(0xFF06B6D4).withOpacity(0.2),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Langkah:',
                                    style: TextStyle(
                                      color: Color(0xFF22D3EE),
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '1. Buka email Anda (cek juga folder spam)\n'
                                    '2. Klik link verifikasi dari Firebase\n'
                                    '3. Kembali ke app ini\n'
                                    '4. App akan otomatis mendeteksi verifikasi',
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.6),
                                      fontSize: 11,
                                      height: 1.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),

                            // Tombol Sudah Verifikasi
                            ElevatedButton(
                              onPressed: _isChecking
                                  ? null
                                  : () => _checkVerification(),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF06B6D4),
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                elevation: 0,
                              ),
                              child: _isChecking
                                  ? const SizedBox(
                                      height: 18,
                                      width: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                                Colors.white),
                                      ),
                                    )
                                  : const Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.verified_outlined, size: 18),
                                        SizedBox(width: 8),
                                        Text(
                                          'SUDAH VERIFIKASI',
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold,
                                            letterSpacing: 2,
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                            const SizedBox(height: 10),

                            // Kirim ulang
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  'Tidak menerima email? ',
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.4),
                                    fontSize: 11,
                                  ),
                                ),
                                _resendCooldown > 0
                                    ? Text(
                                        'Kirim ulang (${_resendCooldown}s)',
                                        style: TextStyle(
                                          color: Colors.white.withOpacity(0.3),
                                          fontSize: 11,
                                        ),
                                      )
                                    : GestureDetector(
                                        onTap:
                                            _isResending ? null : _handleResend,
                                        child: Text(
                                          _isResending
                                              ? 'Mengirim...'
                                              : 'Kirim ulang',
                                          style: const TextStyle(
                                            color: Color(0xFF22D3EE),
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                              ],
                            ),
                            const SizedBox(height: 6),

                            // Kembali ke login
                            GestureDetector(
                              onTap: () async {
                                _autoCheckTimer?.cancel();
                                // Sign out sebelum kembali ke login
                                await AuthService().logout();
                                if (mounted) {
                                  Navigator.of(context).pushAndRemoveUntil(
                                    MaterialPageRoute(
                                      builder: (context) => const LoginPage(),
                                    ),
                                    (route) => false,
                                  );
                                }
                              },
                              child: Text(
                                'Kembali ke login',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.4),
                                  fontSize: 11,
                                ),
                                textAlign: TextAlign.center,
                              ),
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
}
