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

class ButtonLayout {
  double x, y, size;
  ButtonLayout({required this.x, required this.y, required this.size});
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
  bool _editMode = false;
  String? _selectedElement;
  int _ping = 0;
  Color _lightbarColor = Colors.green;
  DateTime? _pingSentAt;
  double _gyroSmoothed = 0.0;
  Timer? _rumbleCooldown;

  Map<String, bool> _buttons = {
    'cross': false, 'circle': false, 'square': false, 'triangle': false,
    'l1': false, 'r1': false, 'options': false,
    'dpad_up': false, 'dpad_down': false,
    'dpad_left': false, 'dpad_right': false,
  };

  double _lx = 0, _ly = 0;
  double _rx = 0, _ry = 0;
  double _l2 = 0, _r2 = 0;

  StreamSubscription? _gyroSub;
  Timer? _sendTimer;
  Timer? _pingTimer;

  late Map<String, ButtonLayout> _layouts;

  @override
  void initState() {
    super.initState();
    _resetLayouts();
  }

  void _resetLayouts() {
    _layouts = {
      'faceButtons':   ButtonLayout(x: 0.78, y: 0.45, size: 130),
      'leftJoystick':  ButtonLayout(x: 0.12, y: 0.45, size: 110),
      'rightJoystick': ButtonLayout(x: 0.65, y: 0.72, size: 110),
      'dpad':          ButtonLayout(x: 0.12, y: 0.75, size: 110),
      'l1':            ButtonLayout(x: 0.08, y: 0.12, size: 64),
      'r1':            ButtonLayout(x: 0.82, y: 0.12, size: 64),
      'l2':            ButtonLayout(x: 0.20, y: 0.12, size: 64),
      'r2':            ButtonLayout(x: 0.70, y: 0.12, size: 64),
      'options':       ButtonLayout(x: 0.50, y: 0.12, size: 70),
    };
  }

  void _connect() {
    final ip = _ipController.text.trim();
    if (ip.isEmpty) return;
    try {
      _channel = WebSocketChannel.connect(Uri.parse('ws://$ip:8765'));
      setState(() => _connected = true);
      _startSending();
      _startSteering();
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
            setState(() => _ping =
              DateTime.now().difference(_pingSentAt!).inMilliseconds);
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

  void _startSteering() {
    _gyroSub = accelerometerEventStream().listen((event) {
      if (!_gyroEnabled) return;
      final raw = (-event.x / 9.8).clamp(-1.0, 1.0);
      _gyroSmoothed = _gyroSmoothed * 0.7 + raw * 0.3;
      setState(() => _lx = _gyroSmoothed);
    });
  }

  void _handleRumble(double large, double small) async {
    final isImpact = large > 0.5;
    final isMediumHit = large > 0.2 && large <= 0.5;
    final isDriving = small > 0.1 && large < 0.3;

    if (isImpact) {
      await Haptics.vibrate(HapticsType.heavy);
      await Future.delayed(const Duration(milliseconds: 80));
      await Haptics.vibrate(HapticsType.heavy);
    } else if (isMediumHit) {
      await Haptics.vibrate(HapticsType.medium);
    } else if (isDriving) {
      if (_rumbleCooldown == null) {
        await Haptics.vibrate(HapticsType.light);
        _rumbleCooldown = Timer(const Duration(seconds: 3), () {
          _rumbleCooldown = null;
        });
      }
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
    setState(() => isLeft ? _l2 = 1.0 : _r2 = 1.0);
    Haptics.vibrate(HapticsType.medium);
  }

  void _onTriggerRelease(bool isLeft) {
    setState(() => isLeft ? _l2 = 0.0 : _r2 = 0.0);
  }

  void _disconnect() {
    _sendTimer?.cancel();
    _pingTimer?.cancel();
    _gyroSub?.cancel();
    _wsSubscription?.cancel();
    _rumbleCooldown?.cancel();
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
      body: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 32, right: 32, top: 32,
          bottom: MediaQuery.of(context).viewInsets.bottom + 32,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 40),
            const Text('🎮 GamePad',
              style: TextStyle(fontSize: 36, color: Colors.white,
                fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Enter your PC IP address',
              style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 24),
            TextField(
              controller: _ipController,
              style: const TextStyle(color: Colors.white),
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'e.g. 192.168.29.171',
                labelStyle: TextStyle(color: Colors.grey),
                border: OutlineInputBorder(),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.grey)),
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
                child: const Text('Connect',
                  style: TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildController() {
    return Scaffold(
      backgroundColor: const Color(0xFF0d0d1a),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          return Stack(
            children: [
              // Lightbar
              Positioned(
                top: 0, left: 0, right: 0,
                child: Container(height: 4, color: _lightbarColor),
              ),

              // All draggable elements
              ..._layouts.entries.map((entry) {
                final key = entry.key;
                final layout = entry.value;
                return _buildDraggable(key, layout, w, h);
              }),

              // TOP CENTER BAR
              Positioned(
                top: 8, left: 0, right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Ping
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: _pingColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _pingColor.withOpacity(0.4)),
                      ),
                      child: Text('$_ping ms',
                        style: TextStyle(
                          color: _pingColor, fontSize: 10)),
                    ),
                    const SizedBox(width: 8),

                    // Gyro toggle
                    GestureDetector(
                      onTap: () => setState(() {
                        _gyroEnabled = !_gyroEnabled;
                        if (!_gyroEnabled) {
                          _lx = 0.0;
                          _gyroSmoothed = 0.0;
                        }
                      }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: (_gyroEnabled
                            ? Colors.green : Colors.grey).withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _gyroEnabled
                              ? Colors.green : Colors.grey),
                        ),
                        child: Text(
                          _gyroEnabled ? '🌀 ON' : '🌀 OFF',
                          style: TextStyle(
                            color: _gyroEnabled
                              ? Colors.green : Colors.grey,
                            fontSize: 10),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // ★ EDIT BUTTON ★
                    GestureDetector(
                      onTap: () => setState(() {
                        _editMode = !_editMode;
                        _selectedElement = null;
                      }),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: _editMode
                            ? Colors.orange.withOpacity(0.3)
                            : Colors.white10,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _editMode
                              ? Colors.orange : Colors.white30,
                            width: 2),
                        ),
                        child: Text(
                          _editMode ? '✅ DONE' : '✏️ EDIT',
                          style: TextStyle(
                            color: _editMode
                              ? Colors.orange : Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Reset button (only in edit mode)
                    if (_editMode)
                      GestureDetector(
                        onTap: () => setState(() => _resetLayouts()),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.red.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: Colors.red.withOpacity(0.5)),
                          ),
                          child: const Text('↩ RESET',
                            style: TextStyle(
                              color: Colors.red, fontSize: 10)),
                        ),
                      ),
                  ],
                ),
              ),

              // Size slider (shown when element selected in edit mode)
              if (_editMode && _selectedElement != null)
                Positioned(
                  bottom: 40, left: 20, right: 20,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.orange.withOpacity(0.5)),
                    ),
                    child: Row(
                      children: [
                        Text(
                          '📐 ${_selectedElement!.toUpperCase()}',
                          style: const TextStyle(
                            color: Colors.orange, fontSize: 11)),
                        const SizedBox(width: 8),
                        const Text('S',
                          style: TextStyle(color: Colors.white, fontSize: 11)),
                        Expanded(
                          child: Slider(
                            value: _layouts[_selectedElement!]!.size,
                            min: 40,
                            max: 200,
                            activeColor: Colors.orange,
                            onChanged: (val) => setState(() {
                              _layouts[_selectedElement!]!.size = val;
                            }),
                          ),
                        ),
                        const Text('L',
                          style: TextStyle(color: Colors.white, fontSize: 11)),
                      ],
                    ),
                  ),
                ),

              // Disconnect
              Positioned(
                bottom: 6, left: 0, right: 0,
                child: Center(
                  child: TextButton(
                    onPressed: _disconnect,
                    child: const Text('Disconnect',
                      style: TextStyle(color: Colors.red, fontSize: 10)),
                  ),
                ),
              ),

              // Edit mode overlay hint
              if (_editMode)
                Positioned(
                  bottom: 60, left: 0, right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'Drag to move • Tap to select • Slider to resize',
                        style: TextStyle(color: Colors.orange, fontSize: 10),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDraggable(
      String key, ButtonLayout layout, double w, double h) {
    final widget = _buildElement(key, layout.size);
    final isSelected = _selectedElement == key;

    return Positioned(
      left: layout.x * w - layout.size / 2,
      top: layout.y * h - layout.size / 2,
      child: GestureDetector(
        onTap: _editMode
          ? () => setState(() => _selectedElement = key)
          : null,
        onPanUpdate: _editMode ? (details) {
          setState(() {
            layout.x = ((layout.x * w + details.delta.dx) / w)
              .clamp(0.05, 0.95);
            layout.y = ((layout.y * h + details.delta.dy) / h)
              .clamp(0.05, 0.95);
          });
        } : null,
        child: _editMode
          ? Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: isSelected
                    ? Colors.orange : Colors.orange.withOpacity(0.4),
                  width: isSelected ? 2 : 1),
                borderRadius: BorderRadius.circular(12),
                color: Colors.orange.withOpacity(
                  isSelected ? 0.15 : 0.05),
              ),
              child: widget,
            )
          : widget,
      ),
    );
  }

  Widget _buildElement(String key, double size) {
    switch (key) {
      case 'faceButtons':   return _buildFaceButtons(size);
      case 'leftJoystick':  return _buildJoystick(true, size);
      case 'rightJoystick': return _buildJoystick(false, size);
      case 'dpad':          return _buildDpad(size);
      case 'l1':            return _buildShoulderBtn('l1', 'L1', size);
      case 'r1':            return _buildShoulderBtn('r1', 'R1', size);
      case 'l2':            return _buildTrigger(true, size);
      case 'r2':            return _buildTrigger(false, size);
      case 'options':       return _buildSmallButton('options', 'OPTIONS', size);
      default:              return const SizedBox();
    }
  }

  Widget _buildTrigger(bool isLeft, double size) {
    final value = isLeft ? _l2 : _r2;
    Color color = value > 0 ? Colors.orange : Colors.white24;
    return GestureDetector(
      onTapDown: _editMode ? null : (_) => _onTriggerDown(isLeft),
      onTapUp: _editMode ? null : (_) => _onTriggerRelease(isLeft),
      onTapCancel: _editMode ? null : () => _onTriggerRelease(isLeft),
      child: Container(
        width: size, height: size * 0.7,
        decoration: BoxDecoration(
          color: color.withOpacity(0.2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color, width: 2),
        ),
        child: Center(
          child: Text(isLeft ? 'L2' : 'R2',
            style: const TextStyle(color: Colors.white,
              fontSize: 13, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  Widget _buildShoulderBtn(String key, String label, double size) {
    return GestureDetector(
      onTapDown: _editMode ? null : (_) {
        setState(() => _buttons[key] = true);
        Haptics.vibrate(HapticsType.light);
      },
      onTapUp: _editMode ? null :
        (_) => setState(() => _buttons[key] = false),
      onTapCancel: _editMode ? null :
        () => setState(() => _buttons[key] = false),
      child: Container(
        width: size, height: size * 0.6,
        decoration: BoxDecoration(
          color: _buttons[key]! ? Colors.white24 : Colors.white10,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white30),
        ),
        child: Center(
          child: Text(label,
            style: const TextStyle(color: Colors.white,
              fontSize: 13, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  Widget _buildFaceButtons(double size) {
    final btnSize = size * 0.37;
    return SizedBox(
      width: size, height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(top: 0, left: size/2 - btnSize/2,
            child: _buildFaceBtn('triangle', '△', Colors.green, btnSize)),
          Positioned(bottom: 0, left: size/2 - btnSize/2,
            child: _buildFaceBtn('cross', '✕', Colors.blue, btnSize)),
          Positioned(left: 0, top: size/2 - btnSize/2,
            child: _buildFaceBtn('square', '□', Colors.pink, btnSize)),
          Positioned(right: 0, top: size/2 - btnSize/2,
            child: _buildFaceBtn('circle', '○', Colors.red, btnSize)),
        ],
      ),
    );
  }

  Widget _buildFaceBtn(
      String key, String label, Color color, double size) {
    return GestureDetector(
      onTapDown: _editMode ? null : (_) {
        setState(() => _buttons[key] = true);
        Haptics.vibrate(HapticsType.light);
      },
      onTapUp: _editMode ? null :
        (_) => setState(() => _buttons[key] = false),
      onTapCancel: _editMode ? null :
        () => setState(() => _buttons[key] = false),
      child: Container(
        width: size, height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _buttons[key]!
            ? color.withOpacity(0.5) : color.withOpacity(0.15),
          border: Border.all(color: color, width: 2),
        ),
        child: Center(
          child: Text(label,
            style: TextStyle(color: color,
              fontSize: size * 0.4, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  Widget _buildSmallButton(String key, String label, double size) {
    return GestureDetector(
      onTapDown: _editMode ? null : (_) {
        setState(() => _buttons[key] = true);
        Haptics.vibrate(HapticsType.light);
      },
      onTapUp: _editMode ? null :
        (_) => setState(() => _buttons[key] = false),
      onTapCancel: _editMode ? null :
        () => setState(() => _buttons[key] = false),
      child: Container(
        width: size, height: size * 0.5,
        decoration: BoxDecoration(
          color: _buttons[key]! ? Colors.white24 : Colors.white10,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white30),
        ),
        child: Center(
          child: Text(label,
            style: const TextStyle(color: Colors.white, fontSize: 11)),
        ),
      ),
    );
  }

  Widget _buildDpad(double size) {
    final btnSize = size * 0.33;
    return SizedBox(
      width: size, height: size,
      child: Stack(
        children: [
          Positioned(top: 0, left: size/2 - btnSize/2,
            child: _buildDpadBtn('dpad_up', '▲', btnSize)),
          Positioned(bottom: 0, left: size/2 - btnSize/2,
            child: _buildDpadBtn('dpad_down', '▼', btnSize)),
          Positioned(left: 0, top: size/2 - btnSize/2,
            child: _buildDpadBtn('dpad_left', '◀', btnSize)),
          Positioned(right: 0, top: size/2 - btnSize/2,
            child: _buildDpadBtn('dpad_right', '▶', btnSize)),
        ],
      ),
    );
  }

  Widget _buildDpadBtn(String key, String label, double size) {
    return GestureDetector(
      onTapDown: _editMode ? null : (_) {
        setState(() => _buttons[key] = true);
        Haptics.vibrate(HapticsType.light);
      },
      onTapUp: _editMode ? null :
        (_) => setState(() => _buttons[key] = false),
      onTapCancel: _editMode ? null :
        () => setState(() => _buttons[key] = false),
      child: Container(
        width: size, height: size,
        decoration: BoxDecoration(
          color: _buttons[key]! ? Colors.white30 : Colors.white10,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.white24),
        ),
        child: Center(
          child: Text(label,
            style: const TextStyle(color: Colors.white, fontSize: 14)),
        ),
      ),
    );
  }

  Widget _buildJoystick(bool isLeft, double size) {
    return GestureDetector(
      onPanUpdate: _editMode ? null : (details) {
        if (isLeft && !_gyroEnabled) {
          setState(() {
            _lx = ((details.localPosition.dx - size/2) / (size/2))
              .clamp(-1.0, 1.0);
            _ly = ((details.localPosition.dy - size/2) / (size/2))
              .clamp(-1.0, 1.0);
          });
        } else if (!isLeft) {
          setState(() {
            _rx = ((details.localPosition.dx - size/2) / (size/2))
              .clamp(-1.0, 1.0);
            _ry = ((details.localPosition.dy - size/2) / (size/2))
              .clamp(-1.0, 1.0);
          });
        }
      },
      onPanEnd: _editMode ? null : (_) => setState(() {
        if (isLeft && !_gyroEnabled) { _lx = 0; _ly = 0; }
        else if (!isLeft) { _rx = 0; _ry = 0; }
      }),
      child: Container(
        width: size, height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white10,
          border: Border.all(color: Colors.white24, width: 2),
        ),
        child: Center(
          child: Transform.translate(
            offset: Offset(
              (isLeft ? _lx : _rx) * size * 0.27,
              (isLeft ? _ly : _ry) * size * 0.27,
            ),
            child: Container(
              width: size * 0.4, height: size * 0.4,
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