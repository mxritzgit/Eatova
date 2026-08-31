// CONTRACT — the `analyze-meal` error codes against the client that shows them
// (Review 2026-08-31, I1/I2).
//
// Why this file exists: the mapping test in
// test/widgets/meal_analysis_error_mapping_test.dart lists the known codes BY
// HAND and adds "unknown -> fallback". That shape can never see a code the
// server grew after the list was written — and that is exactly how
// `auth_unavailable` (503, added with the GoTrue step deadline) slipped
// through: it fell to `_ => fallback` and told the user to check their
// internet connection while the AUTH SERVER was the thing that was down.
//
// So the codes are read out of the edge function sources and every one of them
// is pushed through the REAL client path
// (`parseAnalyzeMealResponse` -> `mealAnalysisErrorMessage`). A code without a
// deliberate client answer is a finding; a code the client deliberately leaves
// on the flow's fallback has to be named in [_nichtFuerDenClient].
//
// Why on the Dart side and not as a Deno test: CI runs Deno with
// `--allow-env` and deliberately WITHOUT `--allow-read`. A Deno test that
// opens source files is green locally and red in CI, so cross-language
// contracts live in Dart here (same as the guardrails/prefilter mirrors in
// test/repo_rules_test.dart).
//
// The parser is written against SHAPES, not line numbers: `new HttpError(` and
// `{ error: '…' }, <status>` may be reformatted, wrapped or moved freely.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/services/meal_analyzer.dart';
import 'package:eatova/src/widgets/kcal/meal_analysis_sheet.dart';

final AppLocalizations _de = lookupAppLocalizations(const Locale('de'));
final AppLocalizations _en = lookupAppLocalizations(const Locale('en'));

/// The text a flow passes in as `failureMessage`. A sentinel on purpose: an
/// ARB text could accidentally equal a real flow string, and then "fell back"
/// and "was mapped" would be indistinguishable.
const String _ausweichtext = '<Ausweichtext des Flows>';

/// The server's `message` field. German, meant for logs — it must never reach
/// a screen (F9-03), which is asserted for every single code below.
const String _serverDetail = 'Serverdetail, das nie im UI landen darf.';

const String _funktionsOrdner = 'supabase/functions/analyze-meal';

// ---------------------------------------------------------------------------
// The deny list
// ---------------------------------------------------------------------------

/// Server codes that deliberately get NO text of their own, each with its
/// reason. Everything in here describes a CLIENT BUG — a request this app
/// cannot produce — so the flow's own fallback is the honest text; a specific
/// message would only invite the user to fix something that is not theirs.
///
/// A new entry needs a reason of that kind. "We did not get around to it" is
/// not one: that case belongs in the switch in `meal_analysis_sheet.dart`.
const Map<String, String> _nichtFuerDenClient = <String, String>{
  'method_not_allowed':
      'the analyzer only ever sends POST — a 405 means the app was built wrong',
  'unsupported_content_type':
      'the analyzer always sets application/json on the request',
  'invalid_json':
      'the body comes from buildAnalyzeMealBody via jsonEncode, never from the user',
  'invalid_body':
      'same origin: the request shape is code, not input',
};

// ---------------------------------------------------------------------------
// Reading the edge function sources
// ---------------------------------------------------------------------------

/// One error code the function can put into `body.error`, with the HTTP status
/// it ships with and the file it was found in.
class _ServerCode {
  const _ServerCode(this.code, this.status, this.pfad);

  final String code;

  /// Null when the shape was recognised but the status was not — a parser
  /// hole, which [_codesTragenEinenStatus] turns into a loud failure instead
  /// of a silently skipped code.
  final int? status;

  final String pfad;

  @override
  String toString() => '$code (${status ?? 'Status?'}, $pfad)';
}

/// `throw new HttpError(<status>, '<code>', '<message>')` — `\s` matches line
/// breaks, so the wrapped multi-line form reads identically.
final RegExp _httpFehler =
    RegExp(r"""new\s+HttpError\(\s*(\d{3})\s*,\s*['"]([a-z0-9_]+)['"]""");

/// The literal `error:` key of a response body built inline
/// (`jsonResponse(request, { error: 'rate_limited', … }, 429)`). The
/// pass-through `error: error.code` carries no literal and is intentionally
/// not matched — those codes are already covered by [_httpFehler].
final RegExp _koerperFehler = RegExp(r"""\berror\s*:\s*['"]([a-z0-9_]+)['"]""");

/// Index just past the string literal starting at [i] (`'`, `"` or a
/// backtick). Backslash escapes are honoured; a quoted literal ends at the
/// line break at the latest, so one unbalanced quote cannot swallow the file.
/// Template literals simply run to their next unescaped backtick — these
/// sources nest no templates.
int _literalEnde(String quelle, int i) {
  final schluss = quelle[i];
  var j = i + 1;
  while (j < quelle.length) {
    final c = quelle[j];
    if (c == r'\') {
      j += 2;
      continue;
    }
    if (c == schluss) return j + 1;
    if (schluss != '`' && c == '\n') return j;
    j++;
  }
  return quelle.length;
}

/// TypeScript without comments, literal-aware.
///
/// Both halves matter. Without stripping, a rationale that QUOTES a code
/// ("answering 401 here would …") becomes a server code. Cutting every line at
/// its first `//` instead would eat the rest of a line that carries a URL —
/// the P10-03b trap in repo_rules_test.dart, one `'https://…'` and the
/// `HttpError` behind it on the same line is gone from the scan.
String _tsOhneKommentare(String quelle) {
  final aus = StringBuffer();
  var i = 0;
  while (i < quelle.length) {
    final c = quelle[i];
    if (c == "'" || c == '"' || c == '`') {
      final ende = _literalEnde(quelle, i);
      aus.write(quelle.substring(i, ende));
      i = ende;
      continue;
    }
    if (c == '/' && i + 1 < quelle.length) {
      final naechste = quelle[i + 1];
      if (naechste == '/') {
        while (i < quelle.length && quelle[i] != '\n') {
          i++;
        }
        continue;
      }
      if (naechste == '*') {
        final von = i;
        i += 2;
        while (i < quelle.length && !quelle.startsWith('*/', i)) {
          i++;
        }
        i = i + 2 > quelle.length ? quelle.length : i + 2;
        // Keep the line breaks, so nothing merges across lines.
        aus.write('\n' * (quelle.substring(von, i).split('\n').length - 1));
        continue;
      }
    }
    aus.write(c);
    i++;
  }
  return aus.toString();
}

/// The status argument that follows the response-body object whose inside
/// starts at [ab]: walks to the `}` closing that object (string-aware, so a
/// brace inside a message cannot close it early) and reads the number behind
/// the comma. Null when the shape is something else.
int? _statusNachObjekt(String quelle, int ab) {
  var tiefe = 1;
  var i = ab;
  while (i < quelle.length) {
    final c = quelle[i];
    if (c == "'" || c == '"' || c == '`') {
      i = _literalEnde(quelle, i);
      continue;
    }
    if (c == '{') {
      tiefe++;
    } else if (c == '}') {
      tiefe--;
      if (tiefe == 0) {
        final bis = i + 40 > quelle.length ? quelle.length : i + 40;
        final rest = quelle.substring(i + 1, bis);
        final treffer = RegExp(r'^\s*,\s*(\d{3})').firstMatch(rest);
        return treffer == null ? null : int.parse(treffer.group(1)!);
      }
    }
    i++;
  }
  return null;
}

/// Every error code in [quellen] (path -> raw source), keyed by code.
Map<String, _ServerCode> _serverFehlercodes(Map<String, String> quellen) {
  final gefunden = <String, _ServerCode>{};
  for (final eintrag in quellen.entries) {
    final code = _tsOhneKommentare(eintrag.value);
    for (final m in _httpFehler.allMatches(code)) {
      final name = m.group(2)!;
      gefunden[name] =
          _ServerCode(name, int.parse(m.group(1)!), eintrag.key);
    }
    for (final m in _koerperFehler.allMatches(code)) {
      final name = m.group(1)!;
      gefunden[name] =
          _ServerCode(name, _statusNachObjekt(code, m.end), eintrag.key);
    }
  }
  return gefunden;
}

/// All non-test TypeScript of the function. The `_shared/` helpers stay out on
/// purpose: they are used by three functions and emit no code of their own, so
/// a hit there would be ambiguous rather than informative.
Map<String, String> _funktionsQuellen() {
  final ordner = Directory(_funktionsOrdner);
  if (!ordner.existsSync()) {
    fail('$_funktionsOrdner fehlt (aufgeloest von ${Directory.current.path})');
  }
  final quellen = <String, String>{};
  for (final e in ordner.listSync()) {
    if (e is! File) continue;
    final pfad = e.path.replaceAll(r'\', '/');
    if (!pfad.endsWith('.ts') || pfad.endsWith('_test.ts')) continue;
    quellen[pfad] = e.readAsStringSync();
  }
  expect(quellen, isNotEmpty, reason: 'kein .ts in $_funktionsOrdner gelesen');
  return quellen;
}

// ---------------------------------------------------------------------------
// The client path
// ---------------------------------------------------------------------------

/// What the user reads for [eintrag] — through the REAL path, not through a
/// hand-built exception: the server answer goes into
/// `parseAnalyzeMealResponse` (which turns 401/403, 429 and 413 into their own
/// typed errors before any code mapping happens) and the throw from there into
/// `mealAnalysisErrorMessage`.
String _clientText(_ServerCode eintrag, AppLocalizations l10n) {
  final koerper = jsonEncode(<String, dynamic>{
    'error': eintrag.code,
    'message': _serverDetail,
    'requestId': 'req-vertrag',
  });
  try {
    parseAnalyzeMealResponse(eintrag.status!, koerper);
  } on Object catch (fehler) {
    return mealAnalysisErrorMessage(fehler, _ausweichtext, l10n);
  }
  fail('$eintrag: parseAnalyzeMealResponse hat nicht geworfen');
}

// ---------------------------------------------------------------------------

void main() {
  late Map<String, _ServerCode> codes;

  setUpAll(() {
    codes = _serverFehlercodes(_funktionsQuellen());
  });

  group('analyze-meal Fehlercode-Vertrag', () {
    test('der Parser findet ueberhaupt Codes (sonst prueft der Vertrag nichts)',
        () {
      // Without this the rule below would go green on a broken parse: no code
      // found means no finding. Two structural anchors instead of a list of
      // names, so an honest change to a single error path does not fail here:
      // `internal_error` is the outer catch-all and `rate_limited` the 429
      // body — neither can disappear without the function changing shape.
      expect(codes.length, greaterThanOrEqualTo(20),
          reason: 'gefunden: ${codes.keys.toList()..sort()}');
      expect(codes.keys, contains('internal_error'),
          reason: 'der Auffang-Zweig wird ueber die jsonResponse-Form gelesen');
      expect(codes.keys, contains('rate_limited'),
          reason: 'zweite jsonResponse-Form, mit Status hinter dem Objekt');
      expect(codes.values.map((c) => c.code), contains('provider_timeout'),
          reason: 'die mehrzeilige new-HttpError-Form muss gelesen werden');
    });

    test('jeder gefundene Code traegt einen Status jenseits von 2xx', () {
      // A code without a status would be skipped silently, and a code on a 2xx
      // would mean the server answers an error inside a success — both are
      // findings, not reasons to look away.
      final ohneStatus = codes.values
          .where((c) => c.status == null)
          .map((c) => '${c.pfad}: ${c.code}')
          .toList();
      expect(ohneStatus, isEmpty,
          reason: 'Der Parser hat die Form erkannt, aber den Status nicht. '
              'Entweder schreibt die Funktion ihre Antwort neu (dann gehoert '
              '_statusNachObjekt nachgezogen), oder das hier ist gar keine '
              'Antwort, sondern ein error:-Feld in einem Log-Objekt (dann '
              'gehoert _koerperFehler enger gefasst). Stillschweigend '
              'ueberspringen ist beides nicht:\n${ohneStatus.join('\n')}');
      for (final c in codes.values) {
        expect(c.status, greaterThanOrEqualTo(400), reason: '$c');
      }
    });

    test('jeder Servercode hat im Client eine bewusste Antwort', () {
      // THE rule. A new server code is either mapped in
      // meal_analysis_sheet.dart, or short-circuited by its status in
      // meal_analyzer.dart, or named in _nichtFuerDenClient — nothing else
      // counts as a decision.
      final funde = <String>[];
      for (final eintrag in codes.values) {
        if (_nichtFuerDenClient.containsKey(eintrag.code)) continue;
        for (final l10n in <AppLocalizations>[_de, _en]) {
          if (_clientText(eintrag, l10n) == _ausweichtext) {
            funde.add('$eintrag -> ${l10n.localeName}');
          }
        }
      }
      expect(
        funde,
        isEmpty,
        reason: 'Diese Codes von analyze-meal landen im Ausweichtext des '
            'Flows ("pruef deine Internetverbindung"), obwohl der Server '
            'etwas anderes meldet. Entweder gehoeren sie in den switch in '
            'lib/src/widgets/kcal/meal_analysis_sheet.dart, oder mit '
            'Begruendung in _nichtFuerDenClient:\n${funde.join('\n')}',
      );
    });

    test('kein Servercode zeigt dem Nutzer die deutsche Server-Meldung', () {
      // F9-03: `message` is diagnostics. It must not reach a screen through
      // any code — the deliberately unmapped ones included.
      for (final eintrag in codes.values) {
        for (final l10n in <AppLocalizations>[_de, _en]) {
          expect(_clientText(eintrag, l10n), isNot(contains(_serverDetail)),
              reason: '$eintrag');
        }
      }
    });

    test('die Ausnahmeliste beschreibt nur Codes, die es noch gibt', () {
      // Otherwise the list outlives the server and quietly excuses a code
      // nobody sends any more, while the next one with that name is waved
      // through.
      final verwaist =
          _nichtFuerDenClient.keys.where((c) => !codes.containsKey(c)).toList();
      expect(verwaist, isEmpty,
          reason: 'analyze-meal sendet diese Codes nicht mehr — Eintrag in '
              '_nichtFuerDenClient entfernen:\n${verwaist.join('\n')}');
    });
  });

  group('I1 — auth_unavailable', () {
    test('503 auth_unavailable meldet die Analyse als nicht verfuegbar', () {
      // The concrete finding. 503 is the server's ANSWER to a GoTrue lookup
      // that ran into its step deadline; it answers 503 there instead of 401
      // precisely so the client does not sign the user out. Telling that user
      // to check their internet connection is the one thing the situation is
      // not about.
      const eintrag = _ServerCode('auth_unavailable', 503, 'probe');
      expect(_clientText(eintrag, _de), _de.foodAnalysisServiceUnavailableMessage);
      expect(_clientText(eintrag, _en), _en.foodAnalysisServiceUnavailableMessage);
      expect(_clientText(eintrag, _de), isNot(_ausweichtext));
    });

    test('auch direkt ueber die Zuordnung, ohne den Wire-Weg', () {
      // Same statement one layer lower, so a change in
      // parseAnalyzeMealResponse cannot make the assertion above accidentally
      // true through a different exception.
      const fehler = MealAnalysisServerError(
        statusCode: 503,
        code: 'auth_unavailable',
        debugMessage: _serverDetail,
      );
      expect(mealAnalysisErrorMessage(fehler, _ausweichtext, _de),
          _de.foodAnalysisServiceUnavailableMessage);
      expect(mealAnalysisErrorMessage(fehler, _ausweichtext, _en),
          _en.foodAnalysisServiceUnavailableMessage);
    });

    test('der Server sendet den Code wirklich (sonst prueft I1 eine Fiktion)',
        () {
      final eintrag = codes['auth_unavailable'];
      expect(eintrag, isNotNull,
          reason: 'auth_unavailable steht nicht mehr in $_funktionsOrdner — '
              'dann darf der Arm im switch auch wieder weg');
      expect(eintrag!.status, 503);
    });
  });

  group('Rueckfall bleibt sauber', () {
    test('ein wirklich unbekannter Servercode faellt auf den Ausweichtext', () {
      // The counter-check to the rule above: the fix must not turn into a
      // catch-all that hands every unknown code a soothing text. An unknown
      // code is unknown, and the flow's own message is the honest answer.
      for (final code in const <String>[
        'brandneu_2027',
        'http_599',
        'auth_unavailable_x',
      ]) {
        final fehler = MealAnalysisServerError(
          statusCode: 500,
          code: code,
          debugMessage: _serverDetail,
        );
        expect(mealAnalysisErrorMessage(fehler, _ausweichtext, _de),
            _ausweichtext,
            reason: code);
        expect(mealAnalysisErrorMessage(fehler, _ausweichtext, _de),
            isNot(contains(_serverDetail)),
            reason: code);
      }
    });

    test('die bewusst nicht zugeordneten Codes bleiben beim Ausweichtext', () {
      // The deny list is a decision, not a hole: these four really do end up
      // on the fallback, and if one of them ever gets a text of its own the
      // entry has to leave the list with it.
      for (final code in _nichtFuerDenClient.keys) {
        final eintrag = codes[code]!;
        expect(_clientText(eintrag, _de), _ausweichtext, reason: code);
      }
    });
  });

  group('der Quellen-Parser selbst', () {
    // Self-checks on a fixture instead of on the live file: Agent D is editing
    // handler.ts in the same run, and a parser that only proves itself against
    // today's formatting proves nothing about tomorrow's.
    const String probe = '''
// new HttpError(418, 'nur_ein_kommentar', 'x');
/* new HttpError(419, 'auch_nur_kommentar', 'x'); */
function f(request: Request) {
  const hilfe = 'https://eatova.de/hilfe'; throw new HttpError(400, 'invalid_body', 'Ungueltige Anfrage.');
  if (bad) {
    throw new HttpError(415, 'unsupported_content_type', 'Bitte JSON senden.');
  }
  throw new HttpError(
    504,
    'provider_timeout',
    'Analyse hat zu lange gedauert. Bitte erneut versuchen.',
  );
}
function g(request: Request, error: HttpError) {
  if (error instanceof HttpError) {
    return jsonResponse(request, { error: error.code, message: error.publicMessage }, error.status);
  }
  if (limited) {
    return jsonResponse(request, { error: 'rate_limited', rateLimit: { user: { resetAt } } }, 429);
  }
  return jsonResponse(
    request,
    { error: 'internal_error', message: 'Analyse gerade nicht verfuegbar (bald).' },
    500,
  );
}
''';

    test('beide Schreibweisen werden mit ihrem Status gelesen', () {
      final gefunden = _serverFehlercodes(<String, String>{'probe.ts': probe});
      expect(
        <String, int?>{
          for (final e in gefunden.entries) e.key: e.value.status,
        },
        <String, int?>{
          'invalid_body': 400,
          'unsupported_content_type': 415,
          'provider_timeout': 504,
          'rate_limited': 429,
          'internal_error': 500,
        },
      );
    });

    test('ein Code im Kommentar ist kein Servercode', () {
      final gefunden = _serverFehlercodes(<String, String>{'probe.ts': probe});
      expect(gefunden.keys, isNot(contains('nur_ein_kommentar')));
      expect(gefunden.keys, isNot(contains('auch_nur_kommentar')));
    });

    test('ein https:// im Literal schneidet die Zeile nicht ab', () {
      // The P10-03b lesson: a line-cutting comment stripper would drop the
      // HttpError standing BEHIND the URL on the same line — and a code that
      // is never found is a code that never fails.
      final gefunden = _serverFehlercodes(<String, String>{'probe.ts': probe});
      expect(gefunden.keys, contains('invalid_body'));
    });

    test('die Durchreiche error: error.code erfindet keinen Code', () {
      final gefunden = _serverFehlercodes(<String, String>{'probe.ts': probe});
      expect(gefunden.keys, isNot(contains('code')));
      expect(gefunden.keys, hasLength(5));
    });

    test('eine geschweifte Klammer in der Meldung schliesst das Objekt nicht',
        () {
      // The dangerous half: a `}` inside the German message would end the body
      // object early and the status behind it would be read from the wrong
      // place — the code would then be skipped as "ohne Status".
      const mitKlammer = '''
return jsonResponse(request, { error: 'internal_error', message: 'Fehler } hier' }, 500);
''';
      final gefunden =
          _serverFehlercodes(<String, String>{'probe.ts': mitKlammer});
      expect(gefunden['internal_error']?.status, 500);
    });
  });
}
