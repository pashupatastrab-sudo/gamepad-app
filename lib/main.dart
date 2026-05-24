import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:haptic_feedback/haptic_feedback.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'dart:convert';
import 'dart:async';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  WakelockPlus.enable();
  runApp(const GamepadApp());
}

class GamepadApp extends StatelessWidget {
  const GamepadApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const ControllerScreen(),
    );
  }
}

class ControllerScreen extends StatefulWidget {
  const ControllerScreen({super.key});
  @override
  State<ControllerScreen> createState() => _ControllerScreenState();
}

class _ControllerScreenState extends State<ControllerScreen> {
  WebSocketChannel? _channel;
  StreamSubscription? _wsSubscription;
  final TextEditingController _ipController = TextEditingController();
  bool _connected = false;
  bool _gyroEnabled = true;
  int _ping = 0;
  Color _lightbarColor = Colors.green;
  DateTime? _pingSentAt;

  // Button states
  Map<String, bool> _buttons = {
    'cross': false, 'circle': false, 'square': false, 'triangle': false,
    'l1': false, 'r1': false, 'options': false,
    'dpad_up': false, 'dpad_down': false, 'dpad_left': false, 'dpad_right': false,
  };

  double _lx = 0, _ly = 0;
  double _rx = 0, _ry = 0;
  double _l2 = 0, _r2 = 0;

  StreamSubscription? _gyroSub;
  Timer? _sendTimer;
  Timer? _pingTimer;
  Timer? _l2Timer1, _l2Timer2;
  Timer? _r2Timer1, _r2Timer2;

  void _connect() {
    final ip = _ipController.text.trim();
    if (ip.isEmpty) return;
    try {
      _channel = WebSocketChannel.connect(Uri.parse('ws://$ip:8765'));
      setState(() => _connected = true);
      _startSending();
      _startGyroscope();
      _startPing();

      _wsSubscription = _channel!.stream.listen((message) {
        final data = jsonDecode(message);
        if (data['type'] == 'rumble') {
          _handleRumble(
            (data['large'] as num).toDouble(),
            (data['small'] as num).toDouble(),
          );
        }
        if (data['type'] == 'pong') {
          if (_pingSentAt != null) {
            setState(() => _ping = DateTime.now().difference(_pingSentAt!).inMilliseconds);
          }
        }
        if (data['type'] == 'health') {
          _updateLightbar((data['value'] as num).toDouble());
        }
      });
    } catch (e) {
      debugPrint('Connection error: $e');
    }
  }

  void _startSending() {
    _sendTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (_channel == null) return;
      _channel!.sink.add(jsonEncode({
        'type': 'input',
        ..._buttons,
        'lx': _lx, 'ly': _ly,
        'rx': _rx, 'ry': _ry,
        'l2': _l2, 'r2': _r2,
      }));
    });
  }

  void _startPing() {
    _pingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_channel == null) return;
      _pingSentAt = DateTime.now();
      _channel!.sink.add(jsonEncode({'type': 'ping'}));
    });
  }

  void _startGyroscope() {
    _gyroSub = gyroscopeEventStream().listen((event) {
      if (!_gyroEnabled) return;
      setState(() {
        _rx = (event.y / 5.0).clamp(-1.0, 1.0);
        _ry = (event.x / 5.0).clamp(-1.0, 1.0);
      });
    });
  }

  void _handleRumble(double large, double small) async {
    if (large > 0.7) {
      await Haptics.vibrate(HapticsType.heavy);
    } else if (large > 0.3 || small > 0.5) {
      await Haptics.vibrate(HapticsType.medium);
    } else if (large > 0 || small > 0) {
      await Haptics.vibrate(HapticsType.light);
    }
  }

  void _updateLightbar(double health) {
    setState(() {
      if (health > 60) _lightbarColor = Colors.green;
      else if (health > 30) _lightbarColor = Colors.yellow;
      else _lightbarColor = Colors.red;
    });
  }

  void _onTriggerDown(bool isLeft) {
    setState(() => isLeft ? _l2 = 0.3 : _r2 = 0.3);
    Haptics.vibrate(HapticsType.light);

    final t1 = Timer(const Duration(milliseconds: 500), () {
      setState(() => isLeft ? _l2 = 0.6 : _r2 = 0.6);
      Haptics.vibrate(HapticsType.medium);
    });
    final t2 = Timer(const Duration(milliseconds: 1000), () {
      setState(() => isLeft ? _l2 = 1.0 : _r2 = 1.0);
      Haptics.vibrate(HapticsType.heavy);
    });

    if (isLeft) { _l2Timer1 = t1; _l2Timer2 = t2; }
    else { _r2Timer1 = t1; _r2Timer2 = t2; }
  }

  void _onTriggerRelease(bool isLeft) {
    if (isLeft) { _l2Timer1?.cancel(); _l2Timer2?.cancel(); setState(() => _l2 = 0); }
    else { _r2Timer1?.cancel(); _r2Timer2?.cancel(); setState(() => _r2 = 0); }
    Haptics.vibrate(HapticsType.selection);
  }

  void _disconnect() {
    _sendTimer?.cancel();
    _pingTimer?.cancel();
    _gyroSub?.cancel();
    _wsSubscription?.cancel();
    _channel?.sink.close();
    setState(() => _connected = false);
  }

  @override
  void dispose() {
    _disconnect();
    _ipController.dispose();
    super.dispose();
  }

  Color get _pingColor {
    if (_ping < 20) return Colors.green;
    if (_ping < 50) return Colors.yellow;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    return _connected ? _buildController() : _buildConnectScreen();
  }

  Widget _buildConnectScreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🎮 GamePad', style: TextStyle(fontSize: 36, color: Colors.white, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Enter your PC IP address', style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 24),
              TextField(
                controller: _ipController,
                style: const TextStyle(color: Colors.white),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'e.g. 192.168.29.171',
                  labelStyle: TextStyle(color: Colors.grey),
                  border: OutlineInputBorder(),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.grey)),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _connect,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('Connect', style: TextStyle(fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildController() {
    return Scaffold(
      backgroundColor: const Color(0xFF0d0d1a),
      body: Stack(
        children: [
          // Lightbar
          Positioned(
            top: 0, left: 0, right: 0,
            child: Container(
              height: 4,
              color: _lightbarColor,
            ),
          ),

          // Top bar
          Positioned(
            top: 8, left: 0, right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _pingColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _pingColor.withOpacity(0.4)),
                  ),
                  child: Text('$_ping ms', style: TextStyle(color: _pingColor, fontSize: 11)),
                ),
                const SizedBox(width: 10),
                _buildSmallButton('options', 'OPTIONS'),
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: () => setState(() {
                    _gyroEnabled = !_gyroEnabled;
                    if (!_gyroEnabled) { _rx = 0; _ry = 0; }
                  }),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: (_gyroEnabled ? Colors.green : Colors.grey).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _gyroEnabled ? Colors.green : Colors.grey),
                    ),
                    child: Text(
                      _gyroEnabled ? '🌀 Gyro ON' : '🌀 Gyro OFF',
                      style: TextStyle(color: _gyroEnabled ? Colors.green : Colors.grey, fontSize: 11),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Left side
          Positioned(
            left: 16, top: 0, bottom: 0,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(children: [
                  _buildTrigger(true),
                  const SizedBox(width: 8),
                  _buildShoulderBtn('l1', 'L1'),
                ]),
                const SizedBox(height: 16),
                _buildJoystick(true),
                const SizedBox(height: 16),
                _buildDpad(),
              ],
            ),
          ),

          // Right side
          Positioned(
            right: 16, top: 0, bottom: 0,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(children: [
                  _buildShoulderBtn('r1', 'R1'),
                  const SizedBox(width: 8),
                  _buildTrigger(false),
                ]),
                const SizedBox(height: 16),
                _buildFaceButtons(),
                const SizedBox(height: 16),
                _buildJoystick(false),
              ],
            ),
          ),

          // Disconnect
          Positioned(
            bottom: 6, left: 0, right: 0,
            child: Center(
              child: TextButton(
                onPressed: _disconnect,
                child: const Text('Disconnect', style: TextStyle(color: Colors.red, fontSize: 11)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrigger(bool isLeft) {
    final value = isLeft ? _l2 : _r2;
    Color color = value >= 1.0 ? Colors.orange : value >= 0.6 ? Colors.yellow : value >= 0.3 ? Colors.yellow.withOpacity(0.6) : Colors.white24;
    return GestureDetector(
      onTapDown: (_) => _onTriggerDown(isLeft),
      onTapUp: (_) => _onTriggerRelease(isLeft),
      onTapCancel: () => _onTriggerRelease(isLeft),
      child: Container(
        width: 64, height: 52,
        decoration: BoxDecoration(
          color: color.withOpacity(0.2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color, width: 2),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(isLeft ? 'L2' : 'R2', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
            const SizedBox(height: 3),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: LinearProgressIndicator(
                value: value,
                backgroundColor: Colors.white10,
                valueColor: AlwaysStoppedAnimation(color),
                minHeight: 4,
              ),
            ),
            Text('${(value * 100).toInt()}%', style: const TextStyle(color: Colors.white54, fontSize: 9)),
          ],
        ),
      ),
    );
  }

  Widget _buildShoulderBtn(String key, String label) {
    return GestureDetector(
      onTapDown: (_) { setState(() => _buttons[key] = true); Haptics.vibrate(HapticsType.light); },
      onTapUp: (_) => setState(() => _buttons[key] = false),
      onTapCancel: () => setState(() => _buttons[key] = false),
      child: Container(
        width: 64, height: 38,
        decoration: BoxDecoration(
          color: _buttons[key]! ? Colors.white24 : Colors.white10,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white30),
        ),
        child: Center(child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold))),
      ),
    );
  }

  Widget _buildFaceButtons() {
    return SizedBox(
      width: 130, height: 130,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(top: 0, child: _buildFaceBtn('triangle', '△', Colors.green)),
          Positioned(bottom: 0, child: _buildFaceBtn('cross', '✕', Colors.blue)),
          Positioned(left: 0, child: _buildFaceBtn('square', '□', Colors.pink)),
          Positioned(right: 0, child: _buildFaceBtn('circle', '○', Colors.red)),
        ],
      ),
    );
  }

  Widget _buildFaceBtn(String key, String label, Color color) {
    return GestureDetector(
      onTapDown: (_) { setState(() => _buttons[key] = true); Haptics.vibrate(HapticsType.light); },
      onTapUp: (_) => setState(() => _buttons[key] = false),
      onTapCancel: () => setState(() => _buttons[key] = false),
      child: Container(
        width: 48, height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _buttons[key]! ? color.withOpacity(0.5) : color.withOpacity(0.15),
          border: Border.all(color: color, width: 2),
        ),
        child: Center(child: Text(label, style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.bold))),
      ),
    );
  }

  Widget _buildSmallButton(String key, String label) {
    return GestureDetector(
      onTapDown: (_) { setState(() => _buttons[key] = true); Haptics.vibrate(HapticsType.light); },
      onTapUp: (_) => setState(() => _buttons[key] = false),
      onTapCancel: () => setState(() => _buttons[key] = false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: _buttons[key]! ? Colors.white24 : Colors.white10,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white30),
        ),
        child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 11)),
      ),
    );
  }

  Widget _buildDpad() {
    return SizedBox(
      width: 110, height: 110,
      child: Stack(
        children: [
          Positioned(top: 0, left: 37, child: _buildDpadBtn('dpad_up', '▲')),
          Positioned(bottom: 0, left: 37, child: _buildDpadBtn('dpad_down', '▼')),
          Positioned(left: 0, top: 37, child: _buildDpadBtn('dpad_left', '◀')),
          Positioned(right: 0, top: 37, child: _buildDpadBtn('dpad_right', '▶')),
        ],
      ),
    );
  }

  Widget _buildDpadBtn(String key, String label) {
    return GestureDetector(
      onTapDown: (_) { setState(() => _buttons[key] = true); Haptics.vibrate(HapticsType.light); },
      onTapUp: (_) => setState(() => _buttons[key] = false),
      onTapCancel: () => setState(() => _buttons[key] = false),
      child: Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          color: _buttons[key]! ? Colors.white30 : Colors.white10,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.white24),
        ),
        child: Center(child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 14))),
      ),
    );
  }

  Widget _buildJoystick(bool isLeft) {
    return GestureDetector(
      onPanUpdate: (details) {
        setState(() {
          if (isLeft) {
            _lx = ((details.localPosition.dx - 55) / 55).clamp(-1.0, 1.0);
            _ly = ((details.localPosition.dy - 55) / 55).clamp(-1.0, 1.0);
          } else {
            _rx = ((details.localPosition.dx - 55) / 55).clamp(-1.0, 1.0);
            _ry = ((details.localPosition.dy - 55) / 55).clamp(-1.0, 1.0);
          }
        });
      },
      onPanEnd: (_) => setState(() {
        if (isLeft) { _lx = 0; _ly = 0; }
        else { _rx = 0; _ry = 0; }
      }),
      child: Container(
        width: 110, height: 110,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white10,
          border: Border.all(color: Colors.white24, width: 2),
        ),
        child: Center(
          child: Transform.translate(
            offset: Offset(
              isLeft ? _lx * 30 : _rx * 30,
              isLeft ? _ly * 30 : _ry * 30,
            ),
            child: Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white24,
                border: Border.all(color: Colors.white54),
              ),
            ),
          ),
        ),
      ),
    );
  }
}