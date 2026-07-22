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
      ),
      home: const SplashScreen(),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fade;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 2));
    _fade = Tween<double>(begin: 0, end: 1).animate(_ctrl);
    _ctrl.forward();
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MainScreen()));
    });
  }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0C0C0C),
      body: FadeTransition(opacity: _fade, child: Center(child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('🔥', style: TextStyle(fontSize: 72)),
          const SizedBox(height: 16),
          const Text('AGNIPROTOCOL', style: TextStyle(color: Color(0xFFFF4500), fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: 6)),
          const SizedBox(height: 8),
          Text('MIRROR v2.0', style: TextStyle(color: Colors.grey[600], fontSize: 12, letterSpacing: 4)),
          const SizedBox(height: 48),
          const CircularProgressIndicator(color: Color(0xFFFF4500), strokeWidth: 2),
        ],
      ))),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  static const platform = MethodChannel('com.agniprotocol.mirror/screen');
  static const String SERVER_URL = 'wss://agniprotocol-mirror.onrender.com';

  final _sessionCtrl = TextEditingController();
  WebSocketChannel? _channel;
  bool _isConnected = false;
  bool _isConnecting = false;
  String _status = '○ Not connected';
  Color _statusColor = const Color(0xFF444444);
  String _sessionInfo = '';
  List<String> _logs = [];
  Timer? _keepAliveTimer;
  Timer? _reconnectTimer;
  bool _isSharing = false;

  @override
  void initState() {
    super.initState();
    _loadLastSession();
    // Listen for screen capture frames from native
    platform.setMethodCallHandler(_handleNativeCall);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onFrame') {
      // Screen frame milali — server la pathva
      final List<int> frameData = List<int>.from(call.arguments);
      if (_channel != null) {
        _channel!.sink.add(Uint8ListHelper.fromList(frameData));
      }
    } else if (call.method == 'onSharingStarted') {
      setState(() { _isSharing = true; });
      _addLog('Screen sharing started!');
    } else if (call.method == 'onSharingStopped') {
      setState(() { _isSharing = false; });
      _addLog('Screen sharing stopped');
    }
  }

  Future<void> _loadLastSession() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString('last_session') ?? '';
    if (last.isNotEmpty) _sessionCtrl.text = last;
  }

  void _addLog(String msg) {
    setState(() {
      _logs.insert(0, '[${DateTime.now().toLocal().toString().substring(11, 19)}] $msg');
      if (_logs.length > 50) _logs.removeLast();
    });
  }

  Future<void> _connect() async {
    final sessionId = _sessionCtrl.text.trim().toUpperCase();
    if (sessionId.isEmpty) { _showSnack('Session ID enter kara!'); return; }

    setState(() { _isConnecting = true; _status = '⏳ Connecting...'; _statusColor = const Color(0xFFFFD700); });

    try {
      _channel = WebSocketChannel.connect(Uri.parse(SERVER_URL));
      _channel!.sink.add(jsonEncode({'type': 'client-join', 'sessionId': sessionId}));
      _channel!.stream.listen(_handleMessage, onDone: _onDisconnect, onError: _onError);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_session', sessionId);

      _keepAliveTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        _channel?.sink.add(jsonEncode({'type': 'keepalive'}));
      });

      setState(() {
        _isConnected = true; _isConnecting = false;
        _status = '● LIVE — Connected to host';
        _statusColor = const Color(0xFF00FF88);
        _sessionInfo = 'Session: $sessionId';
      });

      _addLog('Connected: $sessionId');

      // Start screen capture
      await _startScreenCapture();

    } catch (e) {
      setState(() { _isConnecting = false; _status = '✕ Failed'; _statusColor = const Color(0xFFFF4500); });
      _addLog('Error: $e');
    }
  }

  Future<void> _startScreenCapture() async {
    try {
      await platform.invokeMethod('startCapture');
      _addLog('Screen capture requested');
    } catch (e) {
      _addLog('Screen capture error: $e');
    }
  }

  Future<void> _stopScreenCapture() async {
    try {
      await platform.invokeMethod('stopCapture');
    } catch (e) {}
  }

  void _handleMessage(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String);
      final type = msg['type'] as String;
      switch (type) {
        case 'client-ready': _addLog('Client ID: ${msg['clientId']}'); break;
        case 'control': _handleControl(msg['cmd'], msg['data']); break;
        case 'host-disconnected':
          _addLog('Host disconnected');
          setState(() { _status = '⚠ Host disconnected'; _statusColor = const Color(0xFFFFD700); });
          break;
      }
    } catch (e) {}
  }

  void _handleControl(String? cmd, dynamic data) {
    _addLog('Control: $cmd');
    switch (cmd) {
      case 'home': SystemNavigator.pop(); break;
    }
  }

  void _onDisconnect() {
    setState(() { _isConnected = false; _status = '○ Reconnecting...'; _statusColor = const Color(0xFF444444); });
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !_isConnected && _sessionCtrl.text.isNotEmpty) _connect();
    });
  }

  void _onError(dynamic e) {
    setState(() { _status = '✕ Error — reconnecting'; _statusColor = const Color(0xFFFF4500); });
  }

  void _disconnect() {
    _keepAliveTimer?.cancel();
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    _stopScreenCapture();
    setState(() { _isConnected = false; _isConnecting = false; _status = '○ Not connected'; _statusColor = const Color(0xFF444444); _sessionInfo = ''; _isSharing = false; });
    _addLog('Disconnected');
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontFamily: 'monospace')),
      backgroundColor: const Color(0xFF1E1E1E), behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  void dispose() { _keepAliveTimer?.cancel(); _reconnectTimer?.cancel(); _channel?.sink.close(); _sessionCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF080808),
        title: const Row(children: [
          Text('🔥', style: TextStyle(fontSize: 20)),
          SizedBox(width: 8),
          Text('AGNIPROTOCOL MIRROR', style: TextStyle(color: Color(0xFFFF4500), fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 2)),
        ]),
        bottom: PreferredSize(preferredSize: const Size.fromHeight(1), child: Container(height: 1, color: const Color(0xFF2A2A2A))),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Status
          Container(
            width: double.infinity, padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: const Color(0xFF161616), border: Border.all(color: const Color(0xFF2A2A2A)), borderRadius: BorderRadius.circular(8)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_status, style: TextStyle(color: _statusColor, fontSize: 14, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
              if (_sessionInfo.isNotEmpty) ...[const SizedBox(height: 4), Text(_sessionInfo, style: const TextStyle(color: Color(0xFF444444), fontSize: 11, fontFamily: 'monospace'))],
              if (_isSharing) ...[const SizedBox(height: 4), const Text('📱 Screen sharing active', style: TextStyle(color: Color(0xFF00FF88), fontSize: 11, fontFamily: 'monospace'))],
            ]),
          ),
          const SizedBox(height: 24),
          // Session ID
          const Text('SESSION ID', style: TextStyle(color: Color(0xFF666666), fontSize: 10, letterSpacing: 2)),
          const SizedBox(height: 6),
          TextField(
            controller: _sessionCtrl,
            style: const TextStyle(color: Color(0xFFE8E8E8), fontFamily: 'monospace', fontSize: 16, letterSpacing: 2),
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              hintText: 'AGN-XXXXXX', hintStyle: const TextStyle(color: Color(0xFF333333)),
              filled: true, fillColor: const Color(0xFF0A0A0A),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: Color(0xFF2A2A2A))),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: Color(0xFF2A2A2A))),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: Color(0xFFFF4500))),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
          ),
          const SizedBox(height: 16),
          // Button
          if (!_isConnected)
            SizedBox(width: double.infinity, height: 52, child: ElevatedButton(
              onPressed: _isConnecting ? null : _connect,
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF4500), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)), disabledBackgroundColor: const Color(0xFF333333)),
              child: _isConnecting
                ? const Row(mainAxisAlignment: MainAxisAlignment.center, children: [SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)), SizedBox(width: 10), Text('CONNECTING...', style: TextStyle(letterSpacing: 2))])
                : const Text('✅  CONNECT & SHARE SCREEN', style: TextStyle(fontSize: 13, letterSpacing: 1)),
            ))
          else
            SizedBox(width: double.infinity, height: 52, child: ElevatedButton(
              onPressed: _disconnect,
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFCC0000), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))),
              child: const Text('✕  STOP MIRROR', style: TextStyle(fontSize: 13, letterSpacing: 1)),
            )),
          const SizedBox(height: 24),
          // Info
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: const Color(0xFF0A0A0A), border: Border.all(color: const Color(0xFF1E1E1E)), borderRadius: BorderRadius.circular(4)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('HOW IT WORKS', style: TextStyle(color: Color(0xFF444444), fontSize: 9, letterSpacing: 2)),
              const SizedBox(height: 10),
              _row('1', 'Host kade Session ID maaga'),
              _row('2', 'App madhe enter karo → Connect'),
              _row('3', 'Screen auto share hoil'),
              _row('4', 'Phone lock karo — ALIVE!'),
            ]),
          ),
          const SizedBox(height: 24),
          // Log
          const Text('LOG', style: TextStyle(color: Color(0xFF444444), fontSize: 9, letterSpacing: 2)),
          const SizedBox(height: 6),
          Container(
            height: 160, width: double.infinity, padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFF060606), border: Border.all(color: const Color(0xFF1A1A1A)), borderRadius: BorderRadius.circular(4)),
            child: ListView.builder(itemCount: _logs.length, itemBuilder: (_, i) => Text(_logs[i], style: const TextStyle(color: Color(0xFF00CC66), fontSize: 10, fontFamily: 'monospace', height: 1.8))),
          ),
          const SizedBox(height: 20),
          Center(child: Text('AgniProtocol Mirror v2.0 | Ganpat Darade', style: TextStyle(color: Colors.grey[800], fontSize: 10, letterSpacing: 1))),
        ]),
      ),
    );
  }

  Widget _row(String n, String t) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(children: [
      Text(n, style: const TextStyle(color: Color(0xFFFF4500), fontSize: 11, fontFamily: 'monospace')),
      const SizedBox(width: 10),
      Text(t, style: const TextStyle(color: Color(0xFF888888), fontSize: 12)),
    ]),
  );
}

// Helper
class Uint8ListHelper {
  static List<int> fromList(List<int> list) => list;
}
