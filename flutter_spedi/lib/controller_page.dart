import 'package:flutter/material.dart';
import 'login_page.dart';

class ShipControllerPage extends StatefulWidget {
  final String username;

  const ShipControllerPage({
    Key? key,
    required this.username,
  }) : super(key: key);

  @override
  State<ShipControllerPage> createState() => _ShipControllerPageState();
}

class _ShipControllerPageState extends State<ShipControllerPage> {
  double throttleValue = 0.0;
  double steeringValue = 0.0;
  bool isConnected = true;
  double speed = 0.0;
  int heading = 45;
  double depth = 12.5;
  final String cameraIP = '192.168.1.90';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF020617),
              Color(0xFF172554),
              Color(0xFF0f172a),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16.0, vertical: 12.0),
                  child: _buildControlJoysticks(),
                ),
              ),
              _buildStatusBar(),
              _buildWaveDecoration(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.4),
        border: Border(
          bottom: BorderSide(
            color: const Color(0xFF06B6D4).withOpacity(0.3),
            width: 1,
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(
                Icons.anchor,
                color: const Color(0xFF22D3EE),
                size: 28,
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SPEDI',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFFE0F2FE),
                      letterSpacing: 2,
                    ),
                  ),
                  Text(
                    'RC CONTROLLER',
                    style: TextStyle(
                      fontSize: 9,
                      color: const Color(0xFF22D3EE).withOpacity(0.7),
                    ),
                  ),
                ],
              ),
            ],
          ),
          Row(
            children: [
              // Username
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: const Color(0xFF06B6D4).withOpacity(0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.person,
                      size: 16,
                      color: const Color(0xFF22D3EE),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      widget.username,
                      style: const TextStyle(
                        color: Color(0xFF67E8F9),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                Icons.explore,
                color: const Color(0xFF22D3EE),
                size: 18,
              ),
              const SizedBox(width: 6),
              Text(
                'N $heading°',
                style: const TextStyle(
                  color: Color(0xFF67E8F9),
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: isConnected ? Colors.green : Colors.red,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.radio,
                color: const Color(0xFF22D3EE),
                size: 18,
              ),
              const SizedBox(width: 16),
              // Emergency Stop Button
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    setState(() {
                      throttleValue = 0.0;
                      steeringValue = 0.0;
                      speed = 0.0;
                    });
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text('EMERGENCY STOP ACTIVATED'),
                        backgroundColor: Colors.red,
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDC2626),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFFEF4444),
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFDC2626).withOpacity(0.5),
                          blurRadius: 10,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.power_settings_new,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Logout Button
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        backgroundColor: const Color(0xFF0f172a),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(
                            color: const Color(0xFF06B6D4).withOpacity(0.3),
                            width: 2,
                          ),
                        ),
                        title: Text(
                          'Logout',
                          style: TextStyle(color: const Color(0xFF22D3EE)),
                        ),
                        content: Text(
                          'Are you sure you want to logout?',
                          style: TextStyle(color: Colors.white70),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: Text(
                              'Cancel',
                              style: TextStyle(color: Colors.white70),
                            ),
                          ),
                          ElevatedButton(
                            onPressed: () {
                              Navigator.of(context).pop();
                              Navigator.of(context).pushReplacement(
                                MaterialPageRoute(
                                  builder: (context) => const LoginPage(),
                                ),
                              );
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF06B6D4),
                            ),
                            child: const Text('Logout'),
                          ),
                        ],
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFF06B6D4).withOpacity(0.3),
                        width: 2,
                      ),
                    ),
                    child: Icon(
                      Icons.logout,
                      color: const Color(0xFF22D3EE),
                      size: 22,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildControlJoysticks() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWideScreen = constraints.maxWidth > 700;

        if (isWideScreen) {
          return Column(
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      flex: 2,
                      child: _buildThrottleControl(),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 4,
                      child: _buildCameraView(),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: _buildSteeringControl(),
                    ),
                  ],
                ),
              ),
            ],
          );
        } else {
          return Column(
            children: [
              Expanded(
                child: _buildCameraView(),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _buildThrottleControl()),
                  const SizedBox(width: 12),
                  Expanded(child: _buildSteeringControl()),
                ],
              ),
            ],
          );
        }
      },
    );
  }

  Widget _buildCameraView() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFF06B6D4).withOpacity(0.6),
          width: 3,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF06B6D4).withOpacity(0.4),
            blurRadius: 25,
            spreadRadius: 4,
          ),
        ],
      ),
      child: Stack(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.videocam,
                  size: 80,
                  color: const Color(0xFF22D3EE).withOpacity(0.5),
                ),
                const SizedBox(height: 16),
                Text(
                  'CAMERA VIEW',
                  style: TextStyle(
                    color: const Color(0xFF22D3EE).withOpacity(0.5),
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: const Color(0xFF06B6D4).withOpacity(0.3),
                    ),
                  ),
                  child: Text(
                    cameraIP,
                    style: TextStyle(
                      color: const Color(0xFF67E8F9),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.red.withOpacity(0.5),
                              blurRadius: 8,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'LIVE',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}:${DateTime.now().second.toString().padLeft(2, '0')}',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: 12,
            left: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.8),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: const Color(0xFF06B6D4).withOpacity(0.3),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.circle,
                        size: 12,
                        color: isConnected ? Colors.green : Colors.red,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '1080p • 30fps',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    'FPV CAM',
                    style: TextStyle(
                      color: const Color(0xFF22D3EE),
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThrottleControl() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.3),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: const Color(0xFF06B6D4).withOpacity(0.3),
            ),
          ),
          child: const Text(
            'THROTTLE',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF67E8F9),
              letterSpacing: 1,
            ),
          ),
        ),
        const SizedBox(height: 10),
        JoystickWidget(
          size: 160,
          isVertical: true,
          value: throttleValue,
          onChanged: (value) {
            setState(() {
              throttleValue = value;
              speed = (throttleValue.abs() * 25 / 100);
            });
          },
          icon: Icons.waves,
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.4),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: const Color(0xFF06B6D4).withOpacity(0.3),
            ),
          ),
          child: Text(
            '${throttleValue > 0 ? '+' : ''}${throttleValue.toInt()}%',
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Color(0xFF67E8F9),
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSteeringControl() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.3),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: const Color(0xFF06B6D4).withOpacity(0.3),
            ),
          ),
          child: const Text(
            'STEERING',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF67E8F9),
              letterSpacing: 1,
            ),
          ),
        ),
        const SizedBox(height: 10),
        JoystickWidget(
          size: 160,
          isVertical: false,
          value: steeringValue,
          onChanged: (value) {
            setState(() {
              steeringValue = value;
              heading = (45 + (steeringValue * 0.9).toInt()) % 360;
            });
          },
          icon: Icons.navigation,
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.4),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: const Color(0xFF06B6D4).withOpacity(0.3),
            ),
          ),
          child: Text(
            '${steeringValue > 0 ? '+' : ''}${steeringValue.toInt()}%',
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Color(0xFF67E8F9),
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: _buildStatusCard('SPEED', '${speed.toStringAsFixed(1)} kts'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildStatusCard('HEADING', '$heading°'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildStatusCard('DEPTH', '${depth.toStringAsFixed(1)} m'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: const Color(0xFF06B6D4).withOpacity(0.3),
        ),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: const Color(0xFF22D3EE),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Color(0xFF67E8F9),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWaveDecoration() {
    return Container(
      height: 6,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF06B6D4),
            Color(0xFF3B82F6),
            Color(0xFF06B6D4),
          ],
        ),
      ),
    );
  }
}

// ============ JOYSTICK WIDGET ============
class JoystickWidget extends StatefulWidget {
  final double size;
  final bool isVertical;
  final double value;
  final ValueChanged<double> onChanged;
  final IconData icon;

  const JoystickWidget({
    Key? key,
    required this.size,
    required this.isVertical,
    required this.value,
    required this.onChanged,
    required this.icon,
  }) : super(key: key);

  @override
  State<JoystickWidget> createState() => _JoystickWidgetState();
}

class _JoystickWidgetState extends State<JoystickWidget> {
  Offset? dragPosition;
  bool isDragging = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: (details) {
        setState(() {
          isDragging = true;
        });
      },
      onPanUpdate: (details) {
        RenderBox box = context.findRenderObject() as RenderBox;
        Offset localPosition = box.globalToLocal(details.globalPosition);

        double centerX = widget.size / 2;
        double centerY = widget.size / 2;

        double deltaX = localPosition.dx - centerX;
        double deltaY = centerY - localPosition.dy;

        double maxDistance = widget.size / 2 - 35;

        double value;
        if (widget.isVertical) {
          value = (deltaY / maxDistance * 100).clamp(-100.0, 100.0);
        } else {
          value = (deltaX / maxDistance * 100).clamp(-100.0, 100.0);
        }

        widget.onChanged(value);

        setState(() {
          dragPosition = localPosition;
        });
      },
      onPanEnd: (details) {
        setState(() {
          isDragging = false;
          dragPosition = null;
        });
        widget.onChanged(0.0);
      },
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0f172a),
              Color(0xFF1e293b),
            ],
          ),
          border: Border.all(
            color: const Color(0xFF06B6D4).withOpacity(0.4),
            width: 3,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF164e63).withOpacity(0.5),
              blurRadius: 20,
              spreadRadius: 3,
            ),
          ],
        ),
        child: Stack(
          children: [
            if (widget.isVertical) ...[
              Positioned(
                top: 10,
                left: 0,
                right: 0,
                child: Icon(
                  Icons.arrow_upward,
                  color: const Color(0xFF22D3EE),
                  size: 18,
                ),
              ),
              Positioned(
                bottom: 10,
                left: 0,
                right: 0,
                child: Icon(
                  Icons.arrow_downward,
                  color: const Color(0xFF22D3EE).withOpacity(0.5),
                  size: 18,
                ),
              ),
            ] else ...[
              Positioned(
                left: 10,
                top: 0,
                bottom: 0,
                child: Icon(
                  Icons.arrow_back,
                  color: const Color(0xFF22D3EE).withOpacity(0.5),
                  size: 18,
                ),
              ),
              Positioned(
                right: 10,
                top: 0,
                bottom: 0,
                child: Icon(
                  Icons.arrow_forward,
                  color: const Color(0xFF22D3EE),
                  size: 18,
                ),
              ),
            ],
            Center(
              child: Transform.translate(
                offset: _getKnobOffset(),
                child: Container(
                  width: 55,
                  height: 55,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFF22D3EE),
                        Color(0xFF3B82F6),
                      ],
                    ),
                    border: Border.all(
                      color: const Color(0xFF67E8F9),
                      width: 3,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF06B6D4).withOpacity(0.6),
                        blurRadius: 15,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Icon(
                    widget.icon,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Offset _getKnobOffset() {
    double maxDistance = 55.0;
    double percentage = widget.value / 100.0;

    if (widget.isVertical) {
      return Offset(0, -percentage * maxDistance);
    } else {
      return Offset(percentage * maxDistance, 0);
    }
  }
}