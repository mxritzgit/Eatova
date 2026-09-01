// ---------------------------------------------------------------------------
// Headings as jump marks (review 2026-08-29, P9-06).
//
// `header: true` used to exist exactly twice app-wide, both hand-written on a
// single Text. The shared heading widgets carried nothing, so TalkBack's and
// VoiceOver's "headings" navigation found no jump mark on any screen.
//
// This suite checks SEMANTICS NODES, not the presence of a widget: the rank
// scheme (1 = screen title, 2 = section) and — the counter-check — that the
// annotation stays on the title and does not swallow the tap actions of the
// back button, the trailing action or a settings row.
//
// Second round (P9-06c): the titles the shared widgets never touched, because
// those screens draw their own `Text` — today tab, coach tab, picker sheets.
// They are checked the same way: the FULL list of marks with their ranks, in
// reading order, plus the tap actions that must survive.
// ---------------------------------------------------------------------------

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/macro_progress.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/screens/profile_screen.dart';
import 'package:eatova/src/screens/settings/settings_pickers.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/screens/today/today_screen.dart';
import 'package:eatova/src/screens/today/today_texts.dart';
import 'package:eatova/src/services/day_math.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/theme/theme_mode_controller.dart';
import 'package:eatova/src/widgets/design/design.dart';

import 'support/harness.dart';

/// One jump mark: what a screen reader announces and at which rank.
typedef Sprungmarke = ({String label, int level});

/// Every header node in tree order — the order a screen reader steps through.
List<Sprungmarke> _sprungmarken() => find.semantics
    .byPredicate((SemanticsNode node) => node.flagsCollection.isHeader)
    .evaluate()
    .map<Sprungmarke>(
      (SemanticsNode node) => (label: node.label, level: node.headingLevel),
    )
    .toList();

AppLocalizations get _de => lookupAppLocalizations(const Locale('de'));

/// PageHeader reads `context.l10n`, so every case needs the localized tree.
Future<void> _pump(WidgetTester tester, Widget child) => pumpLocalized(
      tester,
      child,
      padding: const EdgeInsets.all(20),
      settle: true,
    );

Widget _profilSeite() => ProfileScreen(
      name: 'Moritz Schneider',
      profile: const UserProfile(),
      weightLog: const WeightLog(),
      stats: LifetimeStats(mealsLogged: 12, weightLogs: 3, longestStreak: 4),
      dailyConsumedKcal: 900,
      dailySteps: 1000,
      healthAuthState: HealthAuthState.unknown,
      healthLastFetch: null,
      onLogWeight: (_) {},
      onEditProfile: () {},
      onOpenSettings: () {},
      onConnectHealth: () {},
      onRefreshHealth: () {},
    );

Widget _einstellungenSeite() {
  final repo = InMemoryAuthRepository(
    initialUser: const EatovaUser(id: 'u1', email: 'jonas@beispiel-mail.de'),
  );
  addTearDown(repo.dispose);
  final controller = ThemeModeController();
  addTearDown(controller.dispose);
  return ThemeModeScope(
    controller: controller,
    child: SettingsScreen(
      email: 'jonas@beispiel-mail.de',
      authRepository: repo,
      onOpenGoals: () {},
      onSignOut: () async {},
      onDeleteAccount: () async {},
      onExportData: () async => '{}',
    ),
  );
}

/// Sunday, 9 August 2026, 10:00 — far from any day boundary, so greeting and
/// eyebrow cannot straddle midnight while the test runs.
final DateTime _jetzt = DateTime(2026, 8, 9, 10);

Widget _heuteTab() => TodayScreen(
      userName: 'Moritz Schneider',
      profile: const UserProfile(),
      consumedKcal: 900,
      burnedKcal: 200,
      macroProgress: MacroProgress.empty,
      meals: const [],
      selectedDate: startOfDay(_jetzt),
      streak: 3,
      onOpenProfile: () {},
      onOpenCoach: () {},
    );

/// The coach greeting reads the wall clock (`DateTime.now()`), not the
/// injectable one — the expectation has to be built the same way.
String _coachBegruessung(AppLocalizations l10n, String vorname) =>
    '${greetingForHour(DateTime.now().hour, l10n)}, $vorname';

void main() {
  group('Rang-Schema der geteilten Ueberschriften', () {
    testWidgets('ScreenTitle ist eine Ueberschrift der Ebene 1',
        (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        ScreenTitle(
          title: 'Essen',
          subtitle: 'Heute',
          trailing: SquareIconButton(
            key: const ValueKey('screen-title-action'),
            icon: Icons.add_rounded,
            semanticLabel: 'Hinzufügen',
            onTap: () {},
          ),
        ),
      );

      final titel = tester.getSemantics(find.text('Essen'));
      final untertitel = tester.getSemantics(find.text('Heute'));
      final aktion =
          tester.getSemantics(find.byKey(const ValueKey('screen-title-action')));
      handle.dispose();

      expect(
        titel,
        isSemantics(label: 'Essen', isHeader: true),
        reason: 'surfaces.dart: ScreenTitle traegt kein header-Flag',
      );
      expect(titel.headingLevel, 1, reason: 'Seitentitel = Ebene 1');
      expect(
        untertitel,
        isSemantics(label: 'Heute', isHeader: false),
        reason: 'nur der Titel ist die Sprungmarke, nicht der Untertitel',
      );
      // Gegenprobe zu PR #53: die Auszeichnung darf die Aktion nicht fressen.
      expect(
        aktion,
        isSemantics(isButton: true, hasTapAction: true, isHeader: false),
      );
    });

    testWidgets('PageHeader ist Ebene 1 und laesst Zurueck und Aktion intakt',
        (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        PageHeader(
          title: 'Mein Profil',
          backKey: const ValueKey('page-header-back'),
          trailing: SquareIconButton(
            key: const ValueKey('page-header-action'),
            icon: Icons.settings_outlined,
            semanticLabel: 'Einstellungen',
            onTap: () {},
          ),
        ),
      );

      final titel = tester.getSemantics(find.text('Mein Profil'));
      final zurueck =
          tester.getSemantics(find.byKey(const ValueKey('page-header-back')));
      final aktion =
          tester.getSemantics(find.byKey(const ValueKey('page-header-action')));
      handle.dispose();

      expect(
        titel,
        isSemantics(label: 'Mein Profil', isHeader: true),
        reason: 'rows.dart: PageHeader traegt kein header-Flag',
      );
      expect(titel.headingLevel, 1, reason: 'Seitentitel = Ebene 1');
      expect(
        zurueck,
        isSemantics(
          isButton: true,
          hasTapAction: true,
          label: 'Zurück',
          isHeader: false,
        ),
        reason: 'die Ueberschrift darf den Zurueck-Knopf nicht verschlucken',
      );
      expect(
        aktion,
        isSemantics(isButton: true, hasTapAction: true, isHeader: false),
      );
    });

    testWidgets('PageHeader.large ist ebenfalls Ebene 1', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, const PageHeader(large: 'Einstellungen'));

      final titel = tester.getSemantics(find.text('Einstellungen'));
      handle.dispose();

      expect(titel, isSemantics(label: 'Einstellungen', isHeader: true));
      expect(titel.headingLevel, 1);
    });

    // HONEST NOTE (mutation run 2026-09-01): the `enabled:` guard in
    // `_maybeHeading` is NOT what keeps this green. Removing it — annotating
    // the empty `Text('')` unconditionally — leaves this case passing, because
    // Flutter drops a header node that has neither a label nor a rect. The
    // case pins the OUTCOME, not the guard; do not read it as proof that
    // `_maybeHeading` still works.
    //
    // The counter-check below is what stops it from being green for the wrong
    // reason (semantics never enabled, `_sprungmarken` matching nothing at
    // all): with a title the very same header must yield exactly one mark.
    testWidgets('PageHeader ohne Titel erzeugt keine leere Sprungmarke',
        (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, const PageHeader());

      final marken = _sprungmarken();
      handle.dispose();

      expect(marken, isEmpty,
          reason: 'eine Sprungmarke ohne Text waere eine Sackgasse');

      final handle2 = tester.ensureSemantics();
      await _pump(tester, const PageHeader(title: 'Mein Profil'));
      final mitTitel = _sprungmarken();
      handle2.dispose();

      expect(
        mitTitel,
        <Sprungmarke>[(label: 'Mein Profil', level: 1)],
        reason: 'derselbe Kopf MIT Titel muss genau eine Marke liefern — '
            'sonst waere das isEmpty oben nur ein stiller Messfehler',
      );
    });

    testWidgets('SectionHeading ist eine Ueberschrift der Ebene 2',
        (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        const SectionHeading(title: 'Dein Plan', trailing: 'Diese Woche'),
      );

      final titel = tester.getSemantics(find.text('Dein Plan'));
      final zusatz = tester.getSemantics(find.text('Diese Woche'));
      handle.dispose();

      expect(
        titel,
        isSemantics(label: 'Dein Plan', isHeader: true),
        reason: 'surfaces.dart: SectionHeading traegt kein header-Flag',
      );
      expect(titel.headingLevel, 2, reason: 'Abschnitt = Ebene 2');
      expect(
        zusatz,
        isSemantics(label: 'Diese Woche', isHeader: false),
        reason: 'der gedaempfte Zusatz ist keine Sprungmarke',
      );
    });

    testWidgets('SettingsGroup-Beschriftung ist Ebene 2 und die Zeile bleibt '
        'tippbar', (tester) async {
      var getippt = 0;
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        SettingsGroup(
          label: 'KONTO',
          children: <Widget>[
            SettingsRow(
              key: const ValueKey('settings-group-row'),
              title: 'Passwort ändern',
              onTap: () => getippt++,
            ),
          ],
        ),
      );

      final beschriftung = tester.getSemantics(find.text('KONTO'));
      final zeile =
          tester.getSemantics(find.byKey(const ValueKey('settings-group-row')));
      handle.dispose();

      expect(
        beschriftung,
        isSemantics(label: 'KONTO', isHeader: true),
        reason: 'rows.dart: die Gruppen-Beschriftung ist die einzige '
            'Abschnitts-Marke der Einstellungen',
      );
      expect(beschriftung.headingLevel, 2);
      expect(zeile, isSemantics(hasTapAction: true, isHeader: false));

      await tester.tap(find.byKey(const ValueKey('settings-group-row')));
      expect(getippt, 1, reason: 'die Zeile reagiert weiterhin auf Tippen');
    });
  });

  group('Sprungmarken auf echten Seiten', () {
    testWidgets('Profil: Titel und die vier Abschnitte in Lesereihenfolge',
        (tester) async {
      final l10n = _de;
      final handle = tester.ensureSemantics();
      await pumpLocalized(
        tester,
        _profilSeite(),
        // Tall enough that the whole page is laid out and every heading
        // reaches the semantics tree.
        surfaceSize: const Size(430, 3000),
        scaffold: false,
        safeArea: false,
        settle: true,
      );

      final marken = _sprungmarken();
      final zurueck =
          tester.getSemantics(find.byKey(const ValueKey('profile-close')));
      final zuEinstellungen = tester
          .getSemantics(find.byKey(const ValueKey('profile-open-settings')));
      handle.dispose();

      expect(
        marken,
        <Sprungmarke>[
          (label: l10n.profileTitle, level: 1),
          (label: l10n.profileSectionPlan, level: 2),
          (label: l10n.profileSectionBody, level: 2),
          (label: l10n.profileSectionDailyGoals, level: 2),
          (label: l10n.profileSectionConnections, level: 2),
        ],
        reason: 'im Navigationsmodus „Überschriften" muss die Profilseite '
            'genau diese Marken in dieser Reihenfolge liefern',
      );
      // Gegenprobe: der Kopf der Seite verliert keine Aktion.
      expect(
        zurueck,
        isSemantics(isButton: true, hasTapAction: true, isHeader: false),
      );
      expect(
        zuEinstellungen,
        isSemantics(isButton: true, hasTapAction: true, isHeader: false),
      );
    });

    testWidgets('Einstellungen: Seitentitel plus die vier Gruppen',
        (tester) async {
      final l10n = _de;
      final handle = tester.ensureSemantics();
      await pumpLocalized(
        tester,
        _einstellungenSeite(),
        surfaceSize: const Size(430, 3000),
        scaffold: false,
        safeArea: false,
        settle: true,
      );

      final marken = _sprungmarken();
      final zurueck =
          tester.getSemantics(find.byKey(const ValueKey('settings-back')));
      handle.dispose();

      expect(
        marken,
        <Sprungmarke>[
          (label: l10n.settingsPageTitle, level: 1),
          (label: l10n.settingsGroupAccount, level: 2),
          (label: l10n.settingsGroupPreferences, level: 2),
          (label: l10n.settingsGroupDataPrivacy, level: 2),
          (label: l10n.settingsGroupDangerZone, level: 2),
        ],
        reason: 'die Seite ist eine ListView: jedes Kind wird in '
            'IndexedSemantics gewickelt, das vertraegliche Geschwister zu '
            'EINEM Knoten verschmilzt. Ohne eigenen Knoten hiesse die Marke '
            'der Ebene 1 „Zurück Einstellungen"',
      );
      // Gegenprobe: der Zurueck-Knopf behaelt seine Tipp-Aktion.
      expect(
        zurueck,
        isSemantics(isButton: true, hasTapAction: true, isHeader: false),
      );
    });

    testWidgets('Heute: die Begruessung ist die Ebene-1-Marke ueber den '
        'beiden Abschnitten', (tester) async {
      final l10n = _de;
      final handle = tester.ensureSemantics();
      await withClock(Clock.fixed(_jetzt), () async {
        await pumpLocalized(
          tester,
          _heuteTab(),
          surfaceSize: const Size(430, 3000),
          settle: true,
        );
      });

      final marken = _sprungmarken();
      final profil =
          tester.getSemantics(find.byKey(const ValueKey('today-profile')));
      handle.dispose();

      expect(
        marken,
        <Sprungmarke>[
          (label: todayGreeting(l10n, _jetzt), level: 1),
          (label: l10n.todayMacrosTitle, level: 2),
          (label: l10n.todayMealsTitleToday, level: 2),
        ],
        reason: 'der Tab hatte nur Abschnitte (Ebene 2) und keinen '
            'Seitentitel — im Navigationsmodus „Überschriften" landet der '
            'Nutzer mitten in der Seite',
      );
      // Der Bildschirm ist eine ListView: ohne eigenen Knoten haette die
      // Marke die Augenbraue („SONNTAG, 9. AUGUST 2026") mitgelesen.
      expect(
        marken.first.label,
        isNot(contains(todayEyebrow(startOfDay(_jetzt), l10n))),
        reason: 'IndexedSemantics verschmilzt die Kopfzeile zu EINEM Knoten',
      );
      // Gegenprobe: die Profil-Kachel neben dem Titel bleibt tippbar.
      expect(
        profil,
        isSemantics(isButton: true, hasTapAction: true, isHeader: false),
      );
    });

    testWidgets('Coach: der Kopfzeilen-Titel ist Ebene 1, die '
        'Hero-Begruessung darunter Ebene 2', (tester) async {
      final l10n = _de;
      final handle = tester.ensureSemantics();
      await pumpLocalized(
        tester,
        const CoachChatScreen(service: null, userName: 'Moritz Schneider'),
        // The hero is tall; on the binding's 800x600 default it overflows.
        surfaceSize: const Size(402, 900),
        safeArea: false,
        settle: true,
      );

      final marken = _sprungmarken();
      final info = tester.getSemantics(find.byKey(const ValueKey('coach-info')));
      final sitzungen = tester
          .getSemantics(find.byKey(const ValueKey('coach-sessions-open')));
      handle.dispose();

      expect(
        marken,
        <Sprungmarke>[
          (label: l10n.coachTitle, level: 1),
          (label: _coachBegruessung(l10n, 'Moritz'), level: 2),
        ],
        reason: 'der Tab trug gar keine Marke. Genau EINE Ebene 1 (die '
            'immer sichtbare Kopfzeile), die Begruessung des Leerzustands '
            'haengt als Ebene 2 darunter — zwei Ebene-1-Marken waeren eine '
            'Sackgasse',
      );
      // Gegenprobe: die beiden Knoepfe der Kopfzeile behalten ihre Aktion.
      expect(
        info,
        isSemantics(isButton: true, hasTapAction: true, isHeader: false),
      );
      expect(
        sitzungen,
        isSemantics(isButton: true, hasTapAction: true, isHeader: false),
      );
    });

    testWidgets('Picker-Sheet: Titel Ebene 1 ueber der Gruppe Ebene 2',
        (tester) async {
      final l10n = _de;
      BiologicalSex? gewaehlt;
      final handle = tester.ensureSemantics();
      await pumpLocalized(
        tester,
        Builder(
          builder: (context) => TextButton(
            key: const ValueKey('picker-oeffnen'),
            onPressed: () async {
              gewaehlt =
                  await showSexPicker(context, value: BiologicalSex.female);
            },
            child: const Text('Auswahl'),
          ),
        ),
        settle: true,
      );
      await tester.tap(find.byKey(const ValueKey('picker-oeffnen')));
      await tester.pumpAndSettle();

      final marken = _sprungmarken();
      handle.dispose();

      expect(
        marken,
        <Sprungmarke>[
          (label: l10n.goalsFieldSex, level: 1),
          (label: l10n.settingsSexPickerGroupLabel, level: 2),
        ],
        reason: 'die Gruppen-Beschriftung ist seit P9-06 Ebene 2 — ohne den '
            'Sheet-Titel als Ebene 1 haengt sie ueber nichts',
      );

      // Gegenprobe: die Optionszeilen bleiben tippbar und liefern ihren Wert.
      await tester.tap(find.byKey(const ValueKey('settings-sex-male')));
      await tester.pumpAndSettle();
      expect(gewaehlt, BiologicalSex.male);
    });
  });
}
