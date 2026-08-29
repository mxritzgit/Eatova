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
// ---------------------------------------------------------------------------

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/lifetime_stats.dart';
import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/screens/profile_screen.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
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

    testWidgets('PageHeader ohne Titel erzeugt keine leere Sprungmarke',
        (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, const PageHeader());

      final marken = _sprungmarken();
      handle.dispose();

      expect(marken, isEmpty,
          reason: 'eine Sprungmarke ohne Text waere eine Sackgasse');
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
  });
}
