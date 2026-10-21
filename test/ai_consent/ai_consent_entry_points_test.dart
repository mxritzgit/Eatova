// Source rule for the AI consent (review 2026-10-19, P1): every method in
// lib/src that starts a request to analyze-meal, coach-chat or recipe-import
// asks `ensureAiConsent` (or the Coach's `_aiConsentFirst`/`aiConsentSettled`)
// BEFORE the call, in the same method. A new entry point that forgets it
// fails here; the behaviour of each existing one is pinned in the widget
// tests next to this file.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Calls that send to an AI Edge Function from the UI layer.
final Map<String, RegExp> _triggers = <String, RegExp>{
  'MealAnalyzer.analyze (analyze-meal)': RegExp(r'\.analyze\('),
  'MealDescriber.describe (analyze-meal)': RegExp(r'\.describe\('),
  'describe sheet (analyze-meal)': RegExp(r'\bshowMealDescribeSheet\('),
  'RecipeImportService.extract (recipe-import)': RegExp(r'\.extract\('),
  'Coach send funnel (coach-chat)': RegExp(r'\b_coach\.send\('),
};

/// Below the gate by construction, each with the reason.
const Map<String, String> _belowTheGate = <String, String>{
  'lib/src/widgets/kcal/meal_describe_sheet.dart':
      'opened only through showMealDescribeSheet, whose callers ask first',
  'lib/src/screens/coach/coach_chat_controller.dart':
      'called only from the Coach screen\'s _send funnel, which asks first',
};

final RegExp _gate = RegExp(
  r'\bensureAiConsent\(|\b_aiConsentFirst\(|\baiConsentSettled\(',
);

/// Start of a method or top-level function: column 0 or the two-space class
/// member indent, a return type, a name and its parameter list.
final RegExp _methodHead = RegExp(
  r'^(?:  )?(?:static\s+)?(?:Future<[^\n]*?>|void|bool|String|int|Widget|'
  r'[A-Z]\w*(?:<[^\n]*?>)?\??)\s+[_a-zA-Z]\w*\s*[(<]',
  multiLine: true,
);

String _withoutComments(String source) => source
    .split('\n')
    .map((line) {
      final trimmed = line.trimLeft();
      return trimmed.startsWith('//') ? '' : line;
    })
    .join('\n');

/// Violations of the rule in [sources] (path -> Dart source).
List<String> aiConsentViolations(Map<String, String> sources) {
  final violations = <String>[];
  for (final MapEntry(key: path, value: raw) in sources.entries) {
    if (path.startsWith('lib/src/services/') ||
        path.startsWith('lib/src/l10n/') ||
        _belowTheGate.containsKey(path)) {
      continue;
    }
    final code = _withoutComments(raw);
    final heads = _methodHead.allMatches(code).map((m) => m.start).toList();
    for (final MapEntry(key: what, value: pattern) in _triggers.entries) {
      for (final call in pattern.allMatches(code)) {
        final start = heads.lastWhere((h) => h < call.start, orElse: () => 0);
        final before = code.substring(start, call.start);
        if (!_gate.hasMatch(before)) {
          final line =
              '\n'.allMatches(code.substring(0, call.start)).length + 1;
          violations.add(
            '$path:$line calls $what without asking for the AI '
            'consent first in the same method',
          );
        }
      }
    }
  }
  return violations;
}

Map<String, String> _libSources() => <String, String>{
  for (final file
      in Directory('lib/src')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')))
    file.path.replaceAll(r'\', '/'): file.readAsStringSync(),
};

void main() {
  test('jeder KI-Aufruf in lib/src fragt vorher nach der Einwilligung', () {
    expect(aiConsentViolations(_libSources()), isEmpty);
  });

  test(
    'die Ausnahmen gibt es wirklich (kein Tippfehler laesst etwas durch)',
    () {
      for (final path in _belowTheGate.keys) {
        expect(File(path).existsSync(), isTrue, reason: path);
      }
    },
  );

  test('die Regel sieht die Einstiege wirklich', () {
    final sources = _libSources();
    final found = <String>{
      for (final MapEntry(key: path, value: code) in sources.entries)
        for (final pattern in _triggers.values)
          if (pattern.hasMatch(_withoutComments(code))) path,
    };
    expect(
      found,
      containsAll(<String>[
        'lib/src/widgets/kcal/add_meal_sheet.dart',
        'lib/src/screens/meal_analysis_screen.dart',
        'lib/src/screens/recipes/recipe_import_sheet.dart',
        'lib/src/screens/coach/coach_chat_screen.dart',
      ]),
    );
  });

  test('die Regel faengt den alten Zustand und laesst die heutige Form durch',
      () {
    for (final (name, path, source, violations)
        in <(String, String, String, int)>[
      (
        'ein Scan ohne Frage',
        'lib/src/widgets/kcal/x.dart',
        '''
class _S {
  Future<void> _pickAndAnalyze(ImageSource source) async {
    final first = analyzer.analyze(request)..ignore();
  }
}
''',
        1,
      ),
      (
        'die Frage in einer ANDEREN Methode zaehlt nicht',
        'lib/src/widgets/kcal/x.dart',
        '''
class _S {
  Future<void> _openDescribe() async {
    if (!await ensureAiConsent(context) || !mounted) return;
  }

  Future<void> _pickAndAnalyze(ImageSource source) async {
    final first = analyzer.analyze(request)..ignore();
  }
}
''',
        1,
      ),
      (
        'die Frage NACH dem Aufruf zaehlt nicht',
        'lib/src/screens/coach/x.dart',
        '''
class _S {
  Future<void> _send() async {
    await _coach.send(text);
    await ensureAiConsent(context);
  }
}
''',
        1,
      ),
      (
        'die heutige Form ist sauber',
        'lib/src/widgets/kcal/x.dart',
        '''
class _S {
  Future<void> _pickAndAnalyze(ImageSource source) async {
    if (!await ensureAiConsent(context) || !mounted) return;
    final first = analyzer.analyze(request)..ignore();
    retry: () => analyzer.analyze(request);
  }
}
''',
        0,
      ),
    ]) {
      expect(
        aiConsentViolations({path: source}),
        hasLength(violations),
        reason: name,
      );
    }
  });
}
