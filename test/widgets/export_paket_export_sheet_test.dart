// Komplettreview 2026-08-19, Paket „export" — drei Aussagen ueber das
// Datenauskunfts-Sheet:
//
// 1. Der volle Export darf NICHT als ein einziger Paragraph in die Karte. Ein
//    Jahr Nutzung sind mehrere Megabyte JSON; `TextPainter.layout` laeuft auf
//    dem UI-Isolate und fror das Sheet ein. Gezeigt wird eine Vorschau, die
//    vollen Daten gehen ueber Zwischenablage bzw. Datei hinaus.
// 2. Vollstaendigkeit wird nicht mehr behauptet, wenn nichts (oder nur ein
//    Teil) geladen wurde. `buildExportJson` faengt jeden Sektionsfehler
//    einzeln ab und wirft offline nie — am ausbleibenden Fehler ist der Umfang
//    also nicht ablesbar.
// 3. `Clipboard.setData` ist ein Plattformkanal und kann fehlschlagen. Dann
//    gibt es keine Erfolgsmeldung und keinen unbehandelten Zonen-Fehler.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/services/data_export.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/shared/data_export_sheet.dart';

/// Eine Auskunft im echten Format: alle Sektionen da, [mahlzeiten] Zeilen
/// Tagebuch mit JSONB-Nutzlast — so waechst der Text im Feld wirklich.
String _export({
  int mahlzeiten = 0,
  Iterable<String>? sektionen,
  List<String> unvollstaendig = const <String>[],
}) {
  final map = <String, dynamic>{
    'format': DataExportService.formatKennung,
    'exportedAt': '2026-08-19T10:00:00.000Z',
    'userId': 'user-export',
    for (final tabelle in sektionen ?? DataExportService.alleExportTabellen)
      tabelle: <dynamic>[],
    if (unvollstaendig.isNotEmpty) 'unvollstaendig': unvollstaendig,
  };
  if (map.containsKey('logged_meals')) {
    map['logged_meals'] = List.generate(
      mahlzeiten,
      (i) => <String, dynamic>{
        'id': 'meal-$i',
        'logged_at': '2026-08-19T10:00:00.000Z',
        'payload': <String, dynamic>{
          'mealName': 'Mahlzeit $i',
          'kcal': 500 + i,
          'protein_g': 30,
        },
      },
    );
  }
  return const JsonEncoder.withIndent('  ').convert(map);
}

void main() {
  Future<void> zeigeSheet(
    WidgetTester tester, {
    required String auskunft,
    bool vollstaendig = true,
    ExportDateiTeiler? dateiTeilen,
  }) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // `theme: buildEatovaTheme(...)` ist Pflicht: die Karten lesen ihre Farben
    // ueber `AppTokens.of`, und das nackte MaterialApp haengt die
    // ThemeExtension nicht ans Theme.
    await tester.pumpWidget(
      MaterialApp(
        theme: buildEatovaTheme(Brightness.dark),
        locale: const Locale('de'),
        supportedLocales: const <Locale>[Locale('de'), Locale('en')],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: DataExportSheet(
            snapshot: Future<String>.value(auskunft),
            fallbackSnapshot: '',
            vollstaendig: vollstaendig,
            dateiTeilen: dateiTeilen,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('der volle Export gehoert nicht in eine Textflaeche', () {
    testWidgets('die Karte zeigt hoechstens eine Vorschau — samt Hinweis',
        (tester) async {
      final voll = _export(mahlzeiten: 300);
      expect(
        voll.length,
        greaterThan(DataExportSheet.vorschauMaxZeichen),
        reason: 'die Vorlage muss ueberhaupt ueber der Grenze liegen, sonst '
            'prueft der Test nichts',
      );

      await zeigeSheet(tester, auskunft: voll);

      final gezeigt = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(
        gezeigt.data!.length,
        lessThanOrEqualTo(DataExportSheet.vorschauMaxZeichen),
        reason: 'ein Megabyte-JSON als EIN Paragraph blockiert '
            'TextPainter.layout auf dem UI-Isolate — das Sheet friert ein',
      );
      expect(
        find.byKey(const ValueKey('profile-export-shortened')),
        findsOneWidget,
        reason: 'eine stillschweigend gekuerzte Auskunft sieht aus wie eine '
            'unvollstaendige',
      );
    });

    testWidgets('eine kurze Auskunft wird nicht gekuerzt und sagt es auch '
        'nicht', (tester) async {
      await zeigeSheet(tester, auskunft: _export());

      expect(find.byKey(const ValueKey('profile-export-shortened')),
          findsNothing);
    });

    testWidgets('die Datei bekommt die VOLLEN Daten, nicht die Vorschau',
        (tester) async {
      final voll = _export(mahlzeiten: 300);
      String? geteilt;
      String? dateiname;

      await zeigeSheet(
        tester,
        auskunft: voll,
        dateiTeilen: (inhalt, name) async {
          geteilt = inhalt;
          dateiname = name;
        },
      );

      final knopf = find.byKey(const ValueKey('profile-export-share'));
      await tester.ensureVisible(knopf);
      await tester.pumpAndSettle();
      await tester.tap(knopf);
      await tester.pumpAndSettle();

      expect(geteilt, voll,
          reason: 'die Datei ist der Weg fuer die vollstaendigen Daten — sie '
              'darf nicht die Anzeige-Kuerzung erben');
      expect(dateiname, endsWith('.json'));
    });

    testWidgets('ohne Teilen-Weg gibt es den Knopf nicht', (tester) async {
      await zeigeSheet(tester, auskunft: _export());

      expect(find.byKey(const ValueKey('profile-export-share')), findsNothing,
          reason: 'ein Ausgabeweg, den es nicht gibt, ist schlimmer als keiner');
    });
  });

  group('was das Sheet ueber die Vollstaendigkeit behauptet', () {
    testWidgets('alle Sektionen da: vollstaendige Kopie', (tester) async {
      await zeigeSheet(tester, auskunft: _export());

      expect(find.text(deL10n.exportSheetFullSubtitle), findsOneWidget);
    });

    testWidgets('kam KEINE Sektion an, sagt das Sheet genau das', (tester) async {
      // Offline scheitert jede Sektion einzeln — `buildExportJson` wirft
      // trotzdem nicht. Vorher stand hier „Vollständige Kopie deiner
      // gespeicherten Daten" ueber einer Auskunft ohne einen einzigen Datensatz.
      await zeigeSheet(
        tester,
        auskunft: _export(
          sektionen: const <String>[],
          unvollstaendig: DataExportService.alleExportTabellen,
        ),
      );

      expect(find.text(deL10n.exportNothingLoaded), findsOneWidget);
      expect(find.text(deL10n.exportSheetFullSubtitle), findsNothing);
    });

    testWidgets('fehlt eine einzelne Sektion, ist es keine vollstaendige Kopie',
        (tester) async {
      await zeigeSheet(
        tester,
        auskunft: _export(
          sektionen: DataExportService.alleExportTabellen
              .where((t) => t != 'chat_messages'),
          unvollstaendig: const <String>['chat_messages'],
        ),
      );

      expect(find.text(deL10n.exportSheetFullSubtitle), findsNothing);
      expect(find.text(deL10n.exportNothingLoaded), findsNothing);
      expect(find.text(deL10n.exportSheetErrorSubtitle), findsOneWidget);
    });
  });

  group('die Zwischenablage ist ein Plattformkanal', () {
    testWidgets('gelingt die Kopie, bestaetigt das Sheet sie', (tester) async {
      // Ohne Mock-Handler beantwortet der Test-Messenger den Kanal gar nicht,
      // und `invokeMethod` macht daraus eine MissingPluginException — der
      // Erfolgsfall waere also gar nicht erreichbar und der Test pruefte
      // stillschweigend den Fehlerpfad mit.
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => null,
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await zeigeSheet(tester, auskunft: _export());

      await tester.tap(find.byKey(const ValueKey('profile-export-copy')));
      // NICHT pumpAndSettle: der Toast raeumt sich nach kSnackShort selbst ab,
      // und pumpAndSettle laeuft genau bis dorthin — die Bestaetigung waere
      // beim Pruefen schon wieder weg (und der Test damit blind).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text(deL10n.exportSheetCopiedSnack), findsOneWidget);
    });

    testWidgets('scheitert sie, gibt es weder eine Bestaetigung noch einen '
        'unbehandelten Fehler', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            throw PlatformException(code: 'zwischenablage-kaputt');
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await zeigeSheet(tester, auskunft: _export());

      await tester.tap(find.byKey(const ValueKey('profile-export-copy')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: 'ohne try/catch wird daraus ein unbehandelter Zonen-Fehler');
      expect(find.text(deL10n.exportSheetCopiedSnack), findsNothing,
          reason: 'eine Bestaetigung fuer etwas, das nicht passiert ist, ist '
              'dieselbe Sorte Luege wie die Vollstaendigkeits-Behauptung');
    });
  });
}
