import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';

import 'cortex_service.dart';
import 'image_source.dart';

class CortexScreen extends StatefulWidget {
  const CortexScreen({super.key});

  @override
  State<CortexScreen> createState() => _CortexScreenState();
}

class _CortexScreenState extends State<CortexScreen> {
  final FlutterTts _tts = FlutterTts();

  // Swap back to BleCameraSource() here once the firmware sends JPEGs.
  final ImageSource _imageSource = PhoneCameraSource();

  CortexService? _service;
  String? _loadError;

  bool _busy = false;
  Uint8List? _thumbnail;
  CortexResult? _lastResult;
  String? _lastError;
  final List<CortexResult> _history = [];

  @override
  void initState() {
    super.initState();
    CortexService.load().then(
      (s) => setState(() => _service = s),
      onError: (Object e) => setState(() => _loadError = '$e'),
    );
  }

  Future<void> _logRequest(CortexResult result) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/cortex_log.jsonl');
      final line = jsonEncode({
        'timestamp': DateTime.now().toIso8601String(),
        'scenario_id': result.scenarioId,
        'latency_ms': result.latencyMs,
        'used_fallback': result.usedFallback,
        'response': result.response,
      });
      await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
    } catch (e) {
      debugPrint('Cortex log write failed: $e');
    }
  }

  Future<void> _captureAndDescribe() async {
    final service = _service;
    if (service == null || _busy) return;

    Uint8List jpeg;
    try {
      jpeg = await _imageSource.captureJpeg();
    } on ImageCaptureCancelled {
      return;
    } catch (e) {
      setState(() => _lastError = 'Capture failed: $e');
      return;
    }

    setState(() {
      _busy = true;
      _thumbnail = jpeg;
      _lastError = null;
    });

    try {
      final result = await service.describe(jpeg);
      setState(() {
        _lastResult = result;
        _history.insert(0, result);
        if (_history.length > 10) _history.removeLast();
      });
      await _logRequest(result);
      await _tts.speak(result.response);
    } catch (e) {
      debugPrint('Cortex request failed: $e');
      const message = "Couldn't process, try again";
      setState(() => _lastError = message);
      await _tts.speak(message);
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cortex Debug'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_loadError != null)
              Card(
                color: Colors.red.shade900,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('Scenario bank failed to load: $_loadError'),
                ),
              ),

            FilledButton.icon(
              onPressed: (_service != null && !_busy) ? _captureAndDescribe : null,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.camera_alt),
              label: Text(_busy
                  ? 'Processing...'
                  : (_service == null ? 'Loading scenarios...' : 'Capture')),
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
            ),

            const SizedBox(height: 12),

            // Result panel: thumbnail + scenario + response + latency
            Expanded(
              flex: 3,
              child: Card(
                color: _lastError != null ? Colors.red.shade900 : null,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_thumbnail != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            _thumbnail!,
                            width: 96,
                            height: 128,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          ),
                        ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_lastResult != null) ...[
                              Wrap(
                                spacing: 6,
                                children: [
                                  Chip(
                                    label: Text(_lastResult!.scenarioId),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  Chip(
                                    label: Text('${_lastResult!.latencyMs} ms'),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  if (_lastResult!.usedFallback)
                                    const Chip(
                                      label: Text('fallback'),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),
                            ],
                            Expanded(
                              child: SingleChildScrollView(
                                child: Text(
                                  _lastError ??
                                      _lastResult?.response ??
                                      'Take a photo to get a description.',
                                  style: const TextStyle(fontSize: 16, height: 1.5),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),

            // History of the last 10 requests
            Expanded(
              flex: 2,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('History',
                          style: TextStyle(fontSize: 13, color: Colors.grey)),
                      const SizedBox(height: 8),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _history.length,
                          itemBuilder: (context, index) {
                            final r = _history[index];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text(
                                '[${r.scenarioId}] ${r.response}',
                                style: const TextStyle(fontSize: 13),
                              ),
                            );
                          },
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
    );
  }
}
