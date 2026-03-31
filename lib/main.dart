import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:wifi_iot/wifi_iot.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  runApp(const JoystickApp());
}

class JoystickApp extends StatelessWidget {
  const JoystickApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ESP32 Sega Pad',
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF070707),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFD0D0D0),
          secondary: Color(0xFF8F8F8F),
          surface: Color(0xFF111111),
        ),
        textTheme: const TextTheme(
          headlineMedium: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w900,
            letterSpacing: 2.2,
          ),
          titleLarge: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
          ),
          titleMedium: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
          ),
          bodyMedium: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.5,
          ),
        ),
      ),
      home: const ControllerScreen(),
    );
  }
}

enum DriveCommand {
  forward,
  backward,
  left,
  right,
  forwardLeft,
  forwardRight,
  backwardLeft,
  backwardRight,
  stop,
}

enum NoticeTone { neutral, success, warning, error }

extension on DriveCommand {
  String get label {
    switch (this) {
      case DriveCommand.forward:
        return 'FORWARD';
      case DriveCommand.backward:
        return 'BACKWARD';
      case DriveCommand.left:
        return 'LEFT';
      case DriveCommand.right:
        return 'RIGHT';
      case DriveCommand.forwardLeft:
        return 'FORWARD LEFT';
      case DriveCommand.forwardRight:
        return 'FORWARD RIGHT';
      case DriveCommand.backwardLeft:
        return 'BACKWARD LEFT';
      case DriveCommand.backwardRight:
        return 'BACKWARD RIGHT';
      case DriveCommand.stop:
        return 'STOPPED';
    }
  }

  List<DriveCommand> get sequence {
    switch (this) {
      case DriveCommand.forward:
      case DriveCommand.backward:
      case DriveCommand.left:
      case DriveCommand.right:
      case DriveCommand.stop:
        return [this];
      case DriveCommand.forwardLeft:
        return [DriveCommand.forward, DriveCommand.left];
      case DriveCommand.forwardRight:
        return [DriveCommand.forward, DriveCommand.right];
      case DriveCommand.backwardLeft:
        return [DriveCommand.backward, DriveCommand.left];
      case DriveCommand.backwardRight:
        return [DriveCommand.backward, DriveCommand.right];
    }
  }

  String get apiPath {
    switch (this) {
      case DriveCommand.forward:
        return '/forward';
      case DriveCommand.backward:
        return '/backward';
      case DriveCommand.left:
        return '/left';
      case DriveCommand.right:
        return '/right';
      case DriveCommand.stop:
        return '/stop';
      case DriveCommand.forwardLeft:
      case DriveCommand.forwardRight:
      case DriveCommand.backwardLeft:
      case DriveCommand.backwardRight:
        throw StateError(
          'Diagonal commands must be split into direct commands.',
        );
    }
  }
}

class ControllerScreen extends StatefulWidget {
  const ControllerScreen({super.key});

  @override
  State<ControllerScreen> createState() => _ControllerScreenState();
}

class _ControllerScreenState extends State<ControllerScreen> {
  static const String _defaultSsid = 'ESP32_CAR';
  static const String _defaultPassword = '12345678';
  static const String _defaultHost = '192.168.4.1';

  final TextEditingController _ssidController = TextEditingController(
    text: _defaultSsid,
  );
  final TextEditingController _passwordController = TextEditingController(
    text: _defaultPassword,
  );
  final TextEditingController _hostController = TextEditingController(
    text: _defaultHost,
  );

  final Connectivity _connectivity = Connectivity();

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Timer? _reconnectTimer;
  Timer? _statusTimer;
  Timer? _driveTimer;

  DriveCommand _activeCommand = DriveCommand.stop;
  String _wifiText = 'CHECKING';
  String _panelStatus = 'BOOTING';
  String _noticeText = 'STARTING';
  NoticeTone _noticeTone = NoticeTone.neutral;
  bool _connectingWifi = false;
  bool _isEspReachable = false;
  bool _permissionsReady = false;
  bool _passwordVisible = false;
  double _speed = 0.8;
  int _sequenceStep = 0;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _requestPermissions();
    await _refreshConnectionStatus();
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen((_) {
      unawaited(_refreshConnectionStatus());
    });
    _reconnectTimer = Timer.periodic(
      const Duration(seconds: 8),
      (_) => unawaited(_attemptWifiReconnect()),
    );
    _statusTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => unawaited(_refreshConnectionStatus()),
    );
    await _attemptWifiReconnect();
  }

  Future<void> _requestPermissions() async {
    final List<Permission> permissions = [Permission.locationWhenInUse];
    if (await Permission.nearbyWifiDevices.isGranted ||
        await Permission.nearbyWifiDevices.isDenied) {
      permissions.add(Permission.nearbyWifiDevices);
    }

    final Map<Permission, PermissionStatus> statuses = await permissions
        .request();
    _permissionsReady = statuses.values.every(
      (status) => status.isGranted || status.isLimited,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _panelStatus = _permissionsReady ? 'READY' : 'PERMISSION NEEDED';
      _showNotice(
        _permissionsReady ? 'READY' : 'ALLOW WIFI PERMISSION',
        _permissionsReady ? NoticeTone.success : NoticeTone.warning,
      );
    });
  }

  void _showNotice(String text, NoticeTone tone) {
    _noticeText = text;
    _noticeTone = tone;
  }

  Future<void> _refreshConnectionStatus() async {
    final String rawSsid = await WiFiForIoTPlugin.getSSID() ?? 'NOT CONNECTED';
    final String wifiName = _normalizeSsid(rawSsid).isEmpty
        ? 'NOT CONNECTED'
        : _normalizeSsid(rawSsid);
    final bool onCarWifi = wifiName == _ssidController.text.trim();
    final bool reachable = onCarWifi ? await _pingEsp32() : false;

    if (!mounted) {
      return;
    }

    setState(() {
      _wifiText = wifiName;
      _isEspReachable = reachable;

      if (reachable) {
        _panelStatus = 'CONNECTED';
        _showNotice('CONNECTED', NoticeTone.success);
      } else if (onCarWifi) {
        _panelStatus = 'WIFI OK / ESP WAITING';
        _showNotice('ESP32 NOT RESPONDING', NoticeTone.warning);
      } else if (_connectingWifi) {
        _panelStatus = 'AUTO RECONNECTING';
        _showNotice('SEARCHING WIFI', NoticeTone.neutral);
      } else {
        _panelStatus = 'DISCONNECTED';
        _showNotice('WIFI DISCONNECTED', NoticeTone.error);
      }
    });
  }

  Future<void> _attemptWifiReconnect() async {
    if (!_permissionsReady || _connectingWifi) {
      return;
    }

    final String targetSsid = _ssidController.text.trim();
    final String currentSsid = _normalizeSsid(
      await WiFiForIoTPlugin.getSSID() ?? '',
    );
    if (targetSsid.isEmpty || currentSsid == targetSsid) {
      return;
    }

    setState(() {
      _connectingWifi = true;
      _panelStatus = 'AUTO RECONNECTING';
      _showNotice('SEARCHING WIFI', NoticeTone.neutral);
    });

    try {
      await WiFiForIoTPlugin.setEnabled(true, shouldOpenSettings: false);
      await WiFiForIoTPlugin.connect(
        targetSsid,
        password: _passwordController.text,
        joinOnce: false,
        security: NetworkSecurity.WPA,
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _panelStatus = 'RECONNECT FAILED';
          _showNotice('COULD NOT CONNECT', NoticeTone.error);
        });
      }
    } finally {
      _connectingWifi = false;
      await Future<void>.delayed(const Duration(seconds: 2));
      await _refreshConnectionStatus();
    }
  }

  Future<bool> _pingEsp32() async {
    try {
      final response = await http
          .get(Uri.parse('http://${_hostController.text.trim()}/'))
          .timeout(const Duration(seconds: 2));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Duration get _driveInterval {
    final int milliseconds = (260 - (_speed * 170)).round();
    return Duration(milliseconds: milliseconds.clamp(70, 260));
  }

  Future<void> _sendCommand(
    DriveCommand command, {
    bool forceRestart = false,
  }) async {
    if (!forceRestart &&
        command == _activeCommand &&
        command != DriveCommand.stop) {
      return;
    }

    _driveTimer?.cancel();
    _sequenceStep = 0;

    if (mounted) {
      setState(() {
        _activeCommand = command;
      });
    }

    if (command == DriveCommand.stop) {
      await _dispatchDirectCommand(DriveCommand.stop);
      return;
    }

    await _dispatchCurrentStep(command);
    _driveTimer = Timer.periodic(_driveInterval, (_) {
      unawaited(_dispatchCurrentStep(command));
    });
  }

  Future<void> _dispatchCurrentStep(DriveCommand command) async {
    final List<DriveCommand> sequence = command.sequence;
    final DriveCommand directCommand =
        sequence[_sequenceStep % sequence.length];
    _sequenceStep++;
    await _dispatchDirectCommand(directCommand, displayCommand: command);
  }

  Future<void> _dispatchDirectCommand(
    DriveCommand command, {
    DriveCommand? displayCommand,
  }) async {
    final String host = _hostController.text.trim();
    final int speedValue = (_speed * 255).round();

    try {
      await http
          .get(Uri.parse('http://$host${command.apiPath}?speed=$speedValue'))
          .timeout(const Duration(milliseconds: 700));
      if (!mounted) {
        return;
      }
      setState(() {
        _isEspReachable = true;
        _panelStatus = command == DriveCommand.stop
            ? 'STOPPED'
            : (displayCommand ?? command).label;
        _showNotice(
          command == DriveCommand.stop ? 'STOPPED' : 'DRIVING',
          command == DriveCommand.stop
              ? NoticeTone.neutral
              : NoticeTone.success,
        );
      });
    } catch (_) {
      _driveTimer?.cancel();
      if (!mounted) {
        return;
      }
      setState(() {
        _isEspReachable = false;
        _activeCommand = DriveCommand.stop;
        _panelStatus = 'ESP32 NOT REACHABLE';
        _showNotice('FAILED TO REACH ESP32', NoticeTone.error);
      });
    }
  }

  String _normalizeSsid(String value) {
    return value.replaceAll('"', '').trim();
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    _reconnectTimer?.cancel();
    _statusTimer?.cancel();
    _driveTimer?.cancel();
    _ssidController.dispose();
    _passwordController.dispose();
    _hostController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Container(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              colors: [Color(0xFF1A1A1A), Color(0xFF090909), Color(0xFF000000)],
              radius: 1.2,
              center: Alignment(-0.2, -0.3),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Stack(
              children: [
                Row(
                  children: [
                    Expanded(
                      flex: 6,
                      child: Center(
                        child: JoystickPad(
                          onCommandChanged: _sendCommand,
                          activeCommand: _activeCommand,
                        ),
                      ),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      flex: 4,
                      child: _StatusPanel(
                        ssidController: _ssidController,
                        passwordController: _passwordController,
                        hostController: _hostController,
                        passwordVisible: _passwordVisible,
                        statusText: _panelStatus,
                        wifiText: _wifiText,
                        isEspReachable: _isEspReachable,
                        speed: _speed,
                        onReconnectPressed: _attemptWifiReconnect,
                        onStopPressed: () => _sendCommand(DriveCommand.stop),
                        onSpeedChanged: (value) {
                          setState(() {
                            _speed = value;
                          });
                          if (_activeCommand != DriveCommand.stop) {
                            unawaited(
                              _sendCommand(_activeCommand, forceRestart: true),
                            );
                          }
                        },
                        onTogglePasswordVisibility: () {
                          setState(() {
                            _passwordVisible = !_passwordVisible;
                          });
                        },
                      ),
                    ),
                  ],
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: _NoticeBadge(text: _noticeText, tone: _noticeTone),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class JoystickPad extends StatefulWidget {
  const JoystickPad({
    super.key,
    required this.onCommandChanged,
    required this.activeCommand,
  });

  final Future<void> Function(DriveCommand command, {bool forceRestart})
  onCommandChanged;
  final DriveCommand activeCommand;

  @override
  State<JoystickPad> createState() => _JoystickPadState();
}

class _JoystickPadState extends State<JoystickPad> {
  static const double _padSize = 320;
  static const double _knobSize = 140;
  static const double _maxOffset = 54;
  static const double _deadZone = 18;

  Offset _knobOffset = Offset.zero;

  void _updateFromLocalPosition(Offset localPosition) {
    final Offset centered =
        localPosition - const Offset(_padSize / 2, _padSize / 2);
    final double distance = centered.distance;
    final Offset limited = distance > _maxOffset
        ? centered / distance * _maxOffset
        : centered;

    setState(() {
      _knobOffset = limited;
    });

    unawaited(widget.onCommandChanged(_commandFromOffset(limited)));
  }

  DriveCommand _commandFromOffset(Offset offset) {
    if (offset.distance < _deadZone) {
      return DriveCommand.stop;
    }

    final double dx = offset.dx;
    final double dy = offset.dy;
    final bool diagonal = (dx.abs() - dy.abs()).abs() < 22;

    if (diagonal) {
      if (dy < 0 && dx < 0) {
        return DriveCommand.forwardLeft;
      }
      if (dy < 0 && dx > 0) {
        return DriveCommand.forwardRight;
      }
      if (dy > 0 && dx < 0) {
        return DriveCommand.backwardLeft;
      }
      return DriveCommand.backwardRight;
    }

    if (dx.abs() > dy.abs()) {
      return dx > 0 ? DriveCommand.right : DriveCommand.left;
    }

    return dy > 0 ? DriveCommand.backward : DriveCommand.forward;
  }

  void _resetJoystick() {
    setState(() {
      _knobOffset = Offset.zero;
    });
    unawaited(widget.onCommandChanged(DriveCommand.stop));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'ESP32 CONTROL PAD',
          style: Theme.of(
            context,
          ).textTheme.headlineMedium?.copyWith(color: const Color(0xFFF4F4F4)),
        ),
        const SizedBox(height: 18),
        GestureDetector(
          onPanStart: (details) =>
              _updateFromLocalPosition(details.localPosition),
          onPanUpdate: (details) =>
              _updateFromLocalPosition(details.localPosition),
          onPanEnd: (_) => _resetJoystick(),
          onPanCancel: _resetJoystick,
          child: SizedBox(
            width: _padSize,
            height: _padSize,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  size: const Size(_padSize, _padSize),
                  painter: _SegaPadBasePainter(),
                ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 45),
                  left: (_padSize - _knobSize) / 2 + _knobOffset.dx,
                  top: (_padSize - _knobSize) / 2 + _knobOffset.dy,
                  child: CustomPaint(
                    size: const Size(_knobSize, _knobSize),
                    painter: _DPadKnobPainter(),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'CURRENT: ${widget.activeCommand.label}',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(color: const Color(0xFFE5E5E5)),
        ),
      ],
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.ssidController,
    required this.passwordController,
    required this.hostController,
    required this.passwordVisible,
    required this.statusText,
    required this.wifiText,
    required this.isEspReachable,
    required this.speed,
    required this.onReconnectPressed,
    required this.onStopPressed,
    required this.onSpeedChanged,
    required this.onTogglePasswordVisibility,
  });

  final TextEditingController ssidController;
  final TextEditingController passwordController;
  final TextEditingController hostController;
  final bool passwordVisible;
  final String statusText;
  final String wifiText;
  final bool isEspReachable;
  final double speed;
  final Future<void> Function() onReconnectPressed;
  final VoidCallback onStopPressed;
  final ValueChanged<double> onSpeedChanged;
  final VoidCallback onTogglePasswordVisibility;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          colors: [Color(0xFF151515), Color(0xFF080808)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: const Color(0xFF353535)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x88000000),
            blurRadius: 28,
            offset: Offset(0, 16),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: isEspReachable
                          ? const Color(0xFF4ADE80)
                          : const Color(0xFFF97316),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      statusText,
                      style: Theme.of(
                        context,
                      ).textTheme.titleLarge?.copyWith(color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'WIFI: $wifiText',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFFB3B3B3),
                ),
              ),
              const SizedBox(height: 16),
              _PanelField(label: 'SSID', controller: ssidController),
              const SizedBox(height: 12),
              _PanelField(
                label: 'PASSWORD',
                controller: passwordController,
                obscureText: !passwordVisible,
                trailing: IconButton(
                  onPressed: onTogglePasswordVisibility,
                  icon: Icon(
                    passwordVisible ? Icons.visibility_off : Icons.visibility,
                    color: const Color(0xFFD8D8D8),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _PanelField(label: 'HOST', controller: hostController),
              const SizedBox(height: 14),
              Text(
                'SPEED ${(speed * 100).round()}%',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: Colors.white),
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: const Color(0xFFE5E5E5),
                  inactiveTrackColor: const Color(0xFF393939),
                  thumbColor: const Color(0xFFFAFAFA),
                  overlayColor: const Color(0x33FFFFFF),
                ),
                child: Slider(
                  value: speed,
                  min: 0.2,
                  max: 1,
                  divisions: 8,
                  onChanged: onSpeedChanged,
                ),
              ),
              Text(
                'DIAGONALS ARE EMULATED SILENTLY USING YOUR CURRENT ESP32 ENDPOINTS.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF9A9A9A),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonal(
                  onPressed: onReconnectPressed,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: const Color(0xFF222222),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: const Text('RECONNECT'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onStopPressed,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    backgroundColor: const Color(0xFF8F1818),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: const Text('EMERGENCY STOP'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PanelField extends StatelessWidget {
  const _PanelField({
    required this.label,
    required this.controller,
    this.obscureText = false,
    this.trailing,
  });

  final String label;
  final TextEditingController controller;
  final bool obscureText;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(color: const Color(0xFFD2D2D2)),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscureText,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
          ),
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFF0D0D0D),
            suffixIcon: trailing,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 14,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Color(0xFF343434)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Color(0xFFE5E5E5)),
            ),
          ),
        ),
      ],
    );
  }
}

class _NoticeBadge extends StatelessWidget {
  const _NoticeBadge({required this.text, required this.tone});

  final String text;
  final NoticeTone tone;

  @override
  Widget build(BuildContext context) {
    final Color accent = switch (tone) {
      NoticeTone.success => const Color(0xFF57D66E),
      NoticeTone.warning => const Color(0xFFF4B942),
      NoticeTone.error => const Color(0xFFFF5A5A),
      NoticeTone.neutral => const Color(0xFFD6D6D6),
    };

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xCC090909),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: Colors.white),
          ),
        ],
      ),
    );
  }
}

class _SegaPadBasePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);

    final Rect outerRect = Offset.zero & size;
    final Paint outer = Paint()
      ..shader = const RadialGradient(
        colors: [Color(0xFF3D3D3D), Color(0xFF1A1A1A), Color(0xFF060606)],
      ).createShader(outerRect);
    canvas.drawCircle(center, size.width / 2, outer);

    final Paint rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 18
      ..shader = const LinearGradient(
        colors: [Color(0xFF575757), Color(0xFF141414), Color(0xFF444444)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(outerRect);
    canvas.drawCircle(center, size.width / 2 - 10, rim);

    final Paint bowl = Paint()
      ..shader = const RadialGradient(
        colors: [Color(0xFF111111), Color(0xFF000000)],
        radius: 0.82,
      ).createShader(Rect.fromCircle(center: center, radius: size.width / 2.6));
    canvas.drawCircle(center, size.width / 2.8, bowl);

    final Paint gloss = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0x55FFFFFF), Color(0x00FFFFFF)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height / 2));
    final Path glossPath = Path()
      ..addArc(
        Rect.fromCircle(center: center, radius: size.width / 2.15),
        3.5,
        1.1,
      );
    canvas.drawPath(glossPath, gloss);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _DPadKnobPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint body = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF6A6A6A), Color(0xFF333333), Color(0xFF0E0E0E)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(Offset.zero & size);

    final Path cross = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(size.width / 2, size.height / 2),
            width: size.width * 0.34,
            height: size.height * 0.92,
          ),
          const Radius.circular(18),
        ),
      )
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(size.width / 2, size.height / 2),
            width: size.width * 0.92,
            height: size.height * 0.34,
          ),
          const Radius.circular(18),
        ),
      );

    canvas.drawShadow(cross, Colors.black, 16, true);
    canvas.drawPath(cross, body);

    final Paint border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xAA7F7F7F);
    canvas.drawPath(cross, border);

    final Paint centerPaint = Paint()
      ..shader =
          const RadialGradient(
            colors: [Color(0xFF2C2C2C), Color(0xFF080808)],
          ).createShader(
            Rect.fromCircle(
              center: Offset(size.width / 2, size.height / 2),
              radius: size.width * 0.14,
            ),
          );
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      size.width * 0.12,
      centerPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
