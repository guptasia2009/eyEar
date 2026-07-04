import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

const deviceName      = 'EyEar';
const serviceUuid     = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
const textCharUuid    = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';
const commandCharUuid = 'cba1d466-344c-4be3-ab3f-189f80dd7518';

void main() => runApp(const EyEarApp());

class EyEarApp extends StatelessWidget {
  const EyEarApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'eyEar',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const HomePage(),
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
  BluetoothCharacteristic? _cmdChar;

  bool _connected = false;
  bool _scanning = false;
  bool _analyzing = false;

  String _message = 'Not connected.';
  String _buffer = '';

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
          if (uuid == commandCharUuid) _cmdChar = c;
        }
      }
    }

    setState(() {
      _connected = true;
      _scanning = false;
      _message = 'Connected to EyEar.';
    });
  }

  // ESP32 sends the description in 20-byte chunks.
  // A chunk shorter than 20 bytes means it's the last one.
  void _onChunkReceived(List<int> bytes) {
    _buffer += utf8.decode(bytes, allowMalformed: true);
    if (bytes.length < 20) {
      final full = _buffer.trim();
      _buffer = '';
      setState(() { _analyzing = false; _message = full; });
      _tts.speak(full);
    }
  }

  Future<void> _triggerCapture() async {
    if (_cmdChar == null) return;
    setState(() { _analyzing = true; _message = 'Requesting scene description...'; });
    await _cmdChar!.write(utf8.encode('1'), withoutResponse: false);
  }

  Future<void> _disconnect() async {
    await _notifySub?.cancel();
    await _device?.disconnect();
    setState(() {
      _connected = false;
      _device = null;
      _cmdChar = null;
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

            const SizedBox(height: 16),

            // Message display
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Scene Description', style: TextStyle(fontSize: 13, color: Colors.grey)),
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

            const SizedBox(height: 12),

            // Describe scene
            FilledButton.icon(
              onPressed: (_connected && !_analyzing) ? _triggerCapture : null,
              icon: _analyzing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.camera_alt),
              label: Text(_analyzing ? 'Analyzing...' : 'Describe Scene'),
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
            ),
          ],
        ),
      ),
    );
  }
}
