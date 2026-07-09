import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'secrets.dart';

const _model = 'gemini-2.5-flash';
const _endpoint =
    'https://generativelanguage.googleapis.com/v1beta/models/$_model:generateContent';
const _fallbackScenarioId = 'general_description';

class CortexScenario {
  final String id;
  final String category;
  final String triggerDescription;
  final String prompt;
  final String exampleOutput;

  CortexScenario.fromJson(Map<String, dynamic> json)
      : id = json['id'] as String,
        category = json['category'] as String,
        triggerDescription = json['trigger_description'] as String,
        prompt = json['prompt'] as String,
        exampleOutput = json['example_output'] as String;
}

class CortexResult {
  final String scenarioId;
  final String response;
  final int latencyMs;
  final bool usedFallback;

  CortexResult({
    required this.scenarioId,
    required this.response,
    required this.latencyMs,
    this.usedFallback = false,
  });
}

class CortexException implements Exception {
  final String message;
  CortexException(this.message);
  @override
  String toString() => 'CortexException: $message';
}

class CortexService {
  final List<CortexScenario> scenarios;
  final Map<String, CortexScenario> _byId;
  late final String _systemPrompt;

  CortexService._(this.scenarios)
      : _byId = {for (final s in scenarios) s.id: s} {
    _systemPrompt = _buildSystemPrompt();
  }

  static Future<CortexService> load() async {
    final raw = await rootBundle.loadString('assets/cortex_scenarios.json');
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final list = (decoded['scenarios'] as List)
        .map((e) => CortexScenario.fromJson(e as Map<String, dynamic>))
        .toList();
    if (list.every((s) => s.id != _fallbackScenarioId)) {
      throw CortexException(
          'Scenario bank is missing the "$_fallbackScenarioId" fallback.');
    }
    return CortexService._(list);
  }

  String _buildSystemPrompt() {
    final buffer = StringBuffer()
      ..writeln(
          'You are Cortex, the scene-understanding engine of an assistive '
          'wearable for visually impaired users. You receive one photo taken '
          'from the user\'s point of view.')
      ..writeln()
      ..writeln('Follow these two steps:')
      ..writeln('1. Decide which ONE scenario below best matches what the '
          'image shows and what the user most plausibly needs. If nothing '
          'matches well, choose "$_fallbackScenarioId".')
      ..writeln('2. Generate the response following ONLY that scenario\'s '
          'prompt and format. Do not mix formats from other scenarios.')
      ..writeln()
      ..writeln('Scenarios, grouped by category:');

    final categories = <String, List<CortexScenario>>{};
    for (final s in scenarios) {
      categories.putIfAbsent(s.category, () => []).add(s);
    }

    var n = 1;
    categories.forEach((category, list) {
      buffer
        ..writeln()
        ..writeln('## ${category.toUpperCase()}');
      for (final s in list) {
        buffer
          ..writeln('$n. id: ${s.id}')
          ..writeln('   applies when: ${s.triggerDescription}')
          ..writeln('   prompt: ${s.prompt}');
        n++;
      }
    });

    return buffer.toString();
  }

  /// One Gemini call per image: pick the matching scenario, answer in its
  /// format. Retries once on failure; 10 second timeout per attempt.
  Future<CortexResult> describe(Uint8List jpegBytes) async {
    final stopwatch = Stopwatch()..start();
    Object? firstError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final result = await _callOnce(jpegBytes);
        stopwatch.stop();
        return CortexResult(
          scenarioId: result.$1,
          response: result.$2,
          latencyMs: stopwatch.elapsedMilliseconds,
          usedFallback: result.$3,
        );
      } catch (e) {
        firstError = e;
      }
    }
    throw CortexException('Both attempts failed: $firstError');
  }

  Future<(String, String, bool)> _callOnce(Uint8List jpegBytes) async {
    // TODO: Gemini explicit context caching for the system prompt would go
    // here (cachedContents API). Skipped for now: the Dart-side REST call
    // would need cache lifecycle management, and Gemini 2.5 models already
    // apply implicit caching to repeated prefixes automatically.
    final body = jsonEncode({
      'systemInstruction': {
        'parts': [
          {'text': _systemPrompt}
        ]
      },
      'contents': [
        {
          'parts': [
            {
              'inline_data': {
                'mime_type': 'image/jpeg',
                'data': base64Encode(jpegBytes),
              }
            },
            {
              'text': 'Analyze this image and respond per the single best '
                  'matching scenario.'
            }
          ]
        }
      ],
      'generationConfig': {
        'responseMimeType': 'application/json',
        'responseSchema': {
          'type': 'OBJECT',
          'properties': {
            'scenario_id': {'type': 'STRING'},
            'response': {'type': 'STRING'},
          },
          'required': ['scenario_id', 'response'],
        },
      },
    });

    final response = await http
        .post(
          Uri.parse('$_endpoint?key=$geminiApiKey'),
          headers: {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw CortexException('HTTP ${response.statusCode}: ${response.body}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final text = decoded['candidates']?[0]?['content']?['parts']?[0]?['text']
        as String?;
    if (text == null) {
      throw CortexException('No text in Gemini response: ${response.body}');
    }

    final parsed = jsonDecode(text) as Map<String, dynamic>;
    var scenarioId = parsed['scenario_id'] as String? ?? '';
    final answer = parsed['response'] as String? ?? '';
    if (answer.isEmpty) {
      throw CortexException('Empty response field in model output: $text');
    }

    var usedFallback = false;
    if (!_byId.containsKey(scenarioId)) {
      scenarioId = _fallbackScenarioId;
      usedFallback = true;
    }
    return (scenarioId, answer, usedFallback);
  }
}
