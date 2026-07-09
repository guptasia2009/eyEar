import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

import 'cortex_screen.dart';

const deviceName   = 'EyEar';
const serviceUuid  = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
const textCharUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';

void main() => runApp(const EyEarApp());

class EyEarApp extends StatelessWidget {
  const EyEarApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'eyEar',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      // cortex-phone-camera branch: phone-camera debug screen is home.
      // Switch back to HomePage() to return to the BLE flow.
      home: const CortexScreen(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final FlutterTts _tts = FlutterTts();

  BluetoothDevice? _device;

  bool _connected = false;
  bool _scanning = false;

  String _message = 'Not connected.';
  String _buffer = '';
  bool _speakDebug = false;
  bool _isError = false;
  final List<String> _debugLog = [];

  StreamSubscription? _scanSub;
  StreamSubscription? _notifySub;

  @override
  void dispose() {
    _scanSub?.cancel();
    _notifySub?.cancel();
    _device?.disconnect();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  Future<void> _connect() async {
    await _requestPermissions();
    setState(() { _scanning = true; _message = 'Scanning for EyEar...'; });

    _scanSub = FlutterBluePlus.scanResults.listen((results) async {
      for (final r in results) {
        if (r.device.platformName == deviceName) {
          await FlutterBluePlus.stopScan();
          _scanSub?.cancel();
          await _connectToDevice(r.device);
          break;
        }
      }
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

    await Future.delayed(const Duration(seconds: 11));
    if (!_connected) {
      setState(() { _scanning = false; _message = 'EyEar not found. Is it powered on?'; });
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    setState(() { _message = 'Connecting...'; });
    await device.connect();
    _device = device;

    final services = await device.discoverServices();
    for (final s in services) {
      if (s.serviceUuid.toString().toLowerCase() == serviceUuid) {
        for (final c in s.characteristics) {
          final uuid = c.characteristicUuid.toString().toLowerCase();
          if (uuid == textCharUuid) {
            await c.setNotifyValue(true);
            _notifySub = c.onValueReceived.listen(_onChunkReceived);
          }
        }
      }
    }

    setState(() {
      _connected = true;
      _scanning = false;
      _message = 'Connected to EyEar.';
    });
  }

  // ESP32 sends "<type>:<message>" tagged and chunked to 20 bytes,
  // followed by an empty notify marking the end of the message.
  void _onChunkReceived(List<int> bytes) {
    if (bytes.isEmpty) {
      final full = _buffer.trim();
      _buffer = '';
      _routeMessage(full);
      return;
    }
    _buffer += utf8.decode(bytes, allowMalformed: true);
  }

  void _routeMessage(String full) {
    if (full.length < 2) return;
    final type = full[0];
    final content = full.substring(2);
    switch (type) {
      case 'D':
        setState(() {
          _isError = false;
          _message = content;
        });
        _tts.speak(content);
        break;
      case 'E':
        setState(() {
          _isError = true;
          _message = content;
          _debugLog.add(content);
        });
        _tts.speak(content);
        break;
      case 'S':
      default:
        setState(() {
          _debugLog.add(content);
        });
        if (_speakDebug) _tts.speak(content);
        break;
    }
  }

  Future<void> _disconnect() async {
    await _notifySub?.cancel();
    await _device?.disconnect();
    setState(() {
      _connected = false;
      _device = null;
      _message = 'Disconnected.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('eyEar'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status indicator
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                      size: 28,
                      color: _connected ? Colors.greenAccent : Colors.grey,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _connected ? 'Connected to EyEar' : 'Not connected',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),

            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Speak debug messages'),
              value: _speakDebug,
              onChanged: (v) => setState(() => _speakDebug = v),
            ),

            // Message display
            Expanded(
              flex: 3,
              child: Card(
                color: _isError ? Colors.red.shade900 : null,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isError ? 'Error' : 'Scene Description',
                        style: const TextStyle(fontSize: 13, color: Colors.grey),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Text(_message, style: const TextStyle(fontSize: 17, height: 1.6)),
                        ),
                      ),
                      if (_connected && _message.length > 30)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () => _tts.speak(_message),
                            icon: const Icon(Icons.volume_up, size: 18),
                            label: const Text('Read aloud'),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),

            // Debug log
            Expanded(
              flex: 2,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Debug Log', style: TextStyle(fontSize: 13, color: Colors.grey)),
                      const SizedBox(height: 8),
                      Expanded(
                        child: ListView.builder(
                          reverse: true,
                          itemCount: _debugLog.length,
                          itemBuilder: (context, index) {
                            final entry = _debugLog[_debugLog.length - 1 - index];
                            return Text(entry, style: const TextStyle(fontSize: 13));
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Connect / Disconnect
            FilledButton.icon(
              onPressed: _scanning ? null : (_connected ? _disconnect : _connect),
              icon: _scanning
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Icon(_connected ? Icons.bluetooth_disabled : Icons.bluetooth),
              label: Text(_scanning ? 'Scanning...' : (_connected ? 'Disconnect' : 'Connect to EyEar')),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: _connected ? Colors.redAccent : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
