import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:convert';
import 'dart:async';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const AgniMirrorApp());
}

class AgniMirrorApp extends StatelessWidget {
  const AgniMirrorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AgniProtocol Mirror',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: const Color(0xFFFF4500),
        scaffoldBackgroundColor: const Color(0xFF0C0C0C),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF4500),
          secondary: Color(0xFF00FF88),
          surface: Color(0xFF161616),
        ),
        fontFamily: 'monospace',
      ),
      home: const SplashScreen(),
    );
  }
}

// ══ SPLASH SCREEN ══
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 2));
    _fadeAnim = Tween<double>(begin: 0, end: 1).animate(_ctrl);
    _ctrl.forward();
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const MainScreen()),
        );
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0C0C0C),
      body: FadeTransition(
        opacity: _fadeAnim,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('🔥', style: TextStyle(fontSize: 72)),
              const SizedBox(height: 16),
              const Text(
                'AGNIPROTOCOL',
                style: TextStyle(
                  color: Color(0xFFFF4500),
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 6,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'MIRROR v1.0',
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 12,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 48),
              const CircularProgressIndicator(
                color: Color(0xFFFF4500),
                strokeWidth: 2,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══ MAIN SCREEN ══
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final _sessionCtrl = TextEditingController();
  WebSocketChannel? _channel;
  bool _isConnected = false;
  bool _isConnecting = false;
  String _status = '○ Not connected';
  Color _statusColor = const Color(0xFF444444);
  String _sessionInfo = '';
  List<String> _logs = [];
  Timer? _keepAliveTimer;

  static const String SERVER_URL = 'wss://agniprotocol-mirror.onrender.com';

  @override
  void initState() {
    super.initState();
    _loadLastSession();
  }

  Future<void> _loadLastSession() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString('last_session') ?? '';
    if (last.isNotEmpty) {
      _sessionCtrl.text = last;
    }

    // Check if launched from deep link
    // Auto-connect if session saved
  }

  void _addLog(String msg) {
    setState(() {
      _logs.insert(0, '[${DateTime.now().toLocal().toString().substring(11, 19)}] $msg');
      if (_logs.length > 50) _logs.removeLast();
    });
  }

  Future<void> _connect() async {
    final sessionId = _sessionCtrl.text.trim().toUpperCase();
    if (sessionId.isEmpty) {
      _showSnack('Session ID enter kara!');
      return;
    }

    setState(() {
      _isConnecting = true;
      _status = '⏳ Connecting...';
      _statusColor = const Color(0xFFFFD700);
    });

    try {
      _channel = WebSocketChannel.connect(Uri.parse(SERVER_URL));

      // Join as client
      _channel!.sink.add(jsonEncode({
        'type': 'client-join',
        'sessionId': sessionId,
      }));

      _channel!.stream.listen(
        (msg) => _handleMessage(msg),
        onDone: () => _onDisconnect(),
        onError: (e) => _onError(e),
      );

      // Save session
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_session', sessionId);

      // Keepalive
      _keepAliveTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        _channel?.sink.add(jsonEncode({'type': 'keepalive'}));
      });

      setState(() {
        _isConnected = true;
        _isConnecting = false;
        _status = '● LIVE — Connected to host';
        _statusColor = const Color(0xFF00FF88);
        _sessionInfo = 'Session: $sessionId';
      });

      _addLog('Connected to session: $sessionId');

    } catch (e) {
      setState(() {
        _isConnecting = false;
        _status = '✕ Connection failed';
        _statusColor = const Color(0xFFFF4500);
      });
      _addLog('Error: $e');
    }
  }

  void _handleMessage(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String);
      final type = msg['type'] as String;

      switch (type) {
        case 'client-ready':
          _addLog('Client ID: ${msg['clientId']}');
          break;
        case 'offer':
          _addLog('WebRTC offer received from host');
          break;
        case 'control':
          _handleControl(msg['cmd'], msg['data']);
          break;
        case 'host-disconnected':
          _addLog('Host disconnected — waiting...');
          setState(() {
            _status = '⚠ Host disconnected';
            _statusColor = const Color(0xFFFFD700);
          });
          break;
        case 'alive':
          // Keepalive OK
          break;
      }
    } catch (e) {
      _addLog('Message error: $e');
    }
  }

  void _handleControl(String? cmd, dynamic data) {
    _addLog('Control: $cmd');
    // Android system controls via MethodChannel
    switch (cmd) {
      case 'home':
        SystemNavigator.pop();
        break;
      // Other controls handled natively
    }
  }

  void _onDisconnect() {
    setState(() {
      _isConnected = false;
      _status = '○ Disconnected';
      _statusColor = const Color(0xFF444444);
    });
    _addLog('Disconnected from server');
    // Auto reconnect after 3 seconds
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && !_isConnected && _sessionCtrl.text.isNotEmpty) {
        _connect();
      }
    });
  }

  void _onError(dynamic e) {
    setState(() {
      _status = '✕ Error: reconnecting...';
      _statusColor = const Color(0xFFFF4500);
    });
    _addLog('Error: $e');
  }

  void _disconnect() {
    _keepAliveTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    setState(() {
      _isConnected = false;
      _isConnecting = false;
      _status = '○ Not connected';
      _statusColor = const Color(0xFF444444);
      _sessionInfo = '';
    });
    _addLog('Disconnected by user');
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontFamily: 'monospace')),
        backgroundColor: const Color(0xFF1E1E1E),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  void dispose() {
    _keepAliveTimer?.cancel();
    _channel?.sink.close();
    _sessionCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF080808),
        title: Row(
          children: [
            const Text('🔥', style: TextStyle(fontSize: 20)),
            const SizedBox(width: 8),
            const Text(
              'AGNIPROTOCOL MIRROR',
              style: TextStyle(
                color: Color(0xFFFF4500),
                fontSize: 14,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xFF2A2A2A)),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status Card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF161616),
                border: Border.all(color: const Color(0xFF2A2A2A)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _status,
                    style: TextStyle(
                      color: _statusColor,
                      fontSize: 14,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (_sessionInfo.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      _sessionInfo,
                      style: const TextStyle(
                        color: Color(0xFF444444),
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Session Input
            const Text(
              'SESSION ID',
              style: TextStyle(
                color: Color(0xFF666666),
                fontSize: 10,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _sessionCtrl,
              style: const TextStyle(
                color: Color(0xFFE8E8E8),
                fontFamily: 'monospace',
                fontSize: 16,
                letterSpacing: 2,
              ),
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                hintText: 'AGN-XXXXXX',
                hintStyle: const TextStyle(color: Color(0xFF333333)),
                filled: true,
                fillColor: const Color(0xFF0A0A0A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: const BorderSide(color: Color(0xFFFF4500)),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
            ),

            const SizedBox(height: 16),

            // Connect Button
            if (!_isConnected)
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _isConnecting ? null : _connect,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF4500),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                    disabledBackgroundColor: const Color(0xFF333333),
                  ),
                  child: _isConnecting
                      ? const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            ),
                            SizedBox(width: 10),
                            Text('CONNECTING...', style: TextStyle(letterSpacing: 2)),
                          ],
                        )
                      : const Text(
                          '✅  CONNECT & SHARE SCREEN',
                          style: TextStyle(fontSize: 13, letterSpacing: 1),
                        ),
                ),
              )
            else
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _disconnect,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFCC0000),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  child: const Text(
                    '✕  STOP MIRROR',
                    style: TextStyle(fontSize: 13, letterSpacing: 1),
                  ),
                ),
              ),

            const SizedBox(height: 24),

            // Info box
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0A0A),
                border: Border.all(color: const Color(0xFF1E1E1E)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'HOW IT WORKS',
                    style: TextStyle(
                      color: Color(0xFF444444),
                      fontSize: 9,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _infoRow('1', 'Host kade Session ID maaga'),
                  _infoRow('2', 'Tikhe enter karo aani Connect'),
                  _infoRow('3', 'Screen share permission dya'),
                  _infoRow('4', 'Phone lock karo — connection alive!'),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Log
            const Text(
              'LOG',
              style: TextStyle(
                color: Color(0xFF444444),
                fontSize: 9,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              height: 160,
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF060606),
                border: Border.all(color: const Color(0xFF1A1A1A)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: ListView.builder(
                itemCount: _logs.length,
                itemBuilder: (_, i) => Text(
                  _logs[i],
                  style: const TextStyle(
                    color: Color(0xFF00CC66),
                    fontSize: 10,
                    fontFamily: 'monospace',
                    height: 1.8,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 20),

            // Footer
            Center(
              child: Text(
                'AgniProtocol Mirror v1.0 | Ganpat Darade',
                style: TextStyle(
                  color: Colors.grey[800],
                  fontSize: 10,
                  letterSpacing: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String num, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(
            num,
            style: const TextStyle(
              color: Color(0xFFFF4500),
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 10),
          Text(
            text,
            style: const TextStyle(
              color: Color(0xFF888888),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
