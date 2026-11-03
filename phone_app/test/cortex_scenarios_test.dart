import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/cortex_service.dart';

void main() {
  late List<CortexScenario> scenarios;

  setUpAll(() {
    final raw = File('assets/cortex_scenarios.json').readAsStringSync();
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    scenarios = (decoded['scenarios'] as List)
        .map((e) => CortexScenario.fromJson(e as Map<String, dynamic>))
        .toList();
  });

  test('every scenario parses with non-empty fields', () {
    for (final s in scenarios) {
      expect(s.id, isNotEmpty);
      expect(s.category, isNotEmpty);
      expect(s.triggerDescription, isNotEmpty, reason: s.id);
      expect(s.prompt, isNotEmpty, reason: s.id);
      expect(s.exampleOutput, isNotEmpty, reason: s.id);
    }
  });

  test('scenario ids are unique', () {
    final ids = scenarios.map((s) => s.id).toList();
    expect(ids.toSet().length, ids.length);
  });

  test('general_description fallback is present', () {
    expect(scenarios.map((s) => s.id), contains('general_description'));
  });

  test('bank has more than 100 scenarios', () {
    expect(scenarios.length, greaterThan(100));
  });
}
