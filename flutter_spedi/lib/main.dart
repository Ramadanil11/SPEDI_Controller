import 'package:flutter/material.dart';
import 'login_page.dart';

void main() {
  runApp(const ShipControllerApp());
}

class ShipControllerApp extends StatelessWidget {
  const ShipControllerApp({Key? key}) : super(key: key);

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
      home: const LoginPage(),
    );
  }
}