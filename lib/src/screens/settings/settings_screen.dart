import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/legal_links.dart';
import '../../auth/auth_repository.dart';
import '../../services/secure_screen.dart';
import '../../theme/app_tokens.dart';
import '../../theme/theme_mode_controller.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/design/design.dart';
import '../../widgets/shared/data_export_sheet.dart';
import 'account_change_sheets.dart';
import 'settings_controls.dart';

/// Die Einstellungen — Konto, Anzeige, Daten, Gefahrenzone.
///
/// Aufteilung seit 2026-08-10 (Nutzer-Entscheid): Koerperdaten, Aktivitaet,
/// Ziele, Energie/Makros und Tagesziele leben auf einer EIGENEN Seite
/// ([GoalsScreen], erreichbar ueber „Profil & Ziele"). Hier bleibt, was das
/// Konto und die App betrifft. Ein Screen, der Gewichtseingabe und
/// Kontoloeschung mischte, war der Grund, warum das abgeloeste Sheet auf
/// 1922 Zeilen kam.
///
/// **Was die Vorlage zeigt und hier bewusst fehlt** (`Downloads/
/// settings_screen.dart`): „Units Metric/Imperial", „Language" und „Weekly
/// summary email" haben in dieser App keine Funktion — die App ist deutsch und
/// metrisch, und einen Wochen-Report gibt es nicht. Ein Schalter ohne Wirkung
/// ist schlimmer als kein Schalter. Ebenso fehlt „Connected accounts": welcher
/// Anbieter die Anmeldung getragen hat, weiss die App nicht — genauso wenig wie
/// den Bestaetigungsstand, weshalb auch das „VERIFIED"-Abzeichen an der
/// Mailadresse fehlt. Apple Health fehlt, weil die Verbindung im Profil bereits
/// vollstaendig bedienbar ist (`HealthConnectionCard`) — derselbe Zustand an
/// zwei Orten waere ein Fehler.
///
/// „Password" gibt es seit 2026-08-10 dagegen sehr wohl: das [AuthRepository]
/// wird durchgereicht, und mit ihm haengen „Passwort ändern" und
/// „E-Mail-Adresse ändern" in der Gruppe KONTO (Sheets in
/// `account_change_sheets.dart`). Ohne Repository entfallen beide Zeilen
/// ersatzlos — dieselbe Regel wie fuer Export und Ausloggen.
///
/// Der Screen gibt nichts zurueck — jede Aktion laeuft ueber ihren Callback.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.email,
    this.authRepository,
    this.onOpenGoals,
    this.onSignOut,
    this.onDeleteAccount,
    this.onExportData,
  });

  /// Mailadresse der Session. Null in Preview/Tests ohne Auth — die Zeile
  /// wird dann ausgeblendet statt mit einem Platzhalter gefuellt.
  final String? email;

  /// Traegt die Konto-Aenderungen (Passwort, Mailadresse). Null in Preview/
  /// Tests ohne Auth — die beiden Zeilen entfallen dann, statt ins Leere zu
  /// fuehren.
  final AuthRepository? authRepository;

  /// Fuehrt auf „Profil & Ziele".
  final VoidCallback? onOpenGoals;

  final Future<void> Function()? onSignOut;
  final Future<void> Function()? onDeleteAccount;

  /// Liefert die vollstaendige Datenauskunft als JSON (DSGVO Art. 15).
  /// Null ohne Sync — der Eintrag entfaellt dann.
  final Future<String> Function()? onExportData;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// App-Metadaten zur Laufzeit statt hartkodierter Strings, die beim
/// Version-Bump auseinanderlaufen. In Widget-Tests (Kanal nicht gemockt)
/// schlaegt die Future fehl — die Fusszeile faellt dann auf die Wortmarke
/// zurueck.
///
/// Dieselbe Future existiert nochmal privat in `profile_screen.dart`; beide
/// gehoeren in einen gemeinsamen Zugriff (siehe Bericht).
final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

class _SettingsScreenState extends State<SettingsScreen> {
  /// Die Adresse aus der laufenden Sitzung.
  ///
  /// [SettingsScreen.email] wird beim Aufbau der Route eingefroren — nach einem
  /// Adresswechsel stuende dort weiter die alte. Der Konto-Screen ist aber
  /// genau der Ort, an dem man das Ergebnis sehen will, also haengt er selbst
  /// am `authStateChanges`-Strom (dessen Vertrag steht in
  /// `test/auth_account_change_test.dart`).
  String? _sessionEmail;
  StreamSubscription<EatovaUser?>? _sessionSub;

  @override
  void initState() {
    super.initState();
    final repo = widget.authRepository;
    if (repo == null) return;
    _sessionEmail = repo.currentUser?.email;
    _sessionSub = repo.authStateChanges.listen((user) {
      final adresse = user?.email;
      // `null` heisst abgemeldet, nicht „keine Adresse mehr": in dem Fall
      // raeumt der AuthGate diese Route ohnehin ab, und bis dahin ist die
      // zuletzt bekannte Adresse die ehrlichere Anzeige.
      if (!mounted || adresse == null || adresse == _sessionEmail) return;
      setState(() => _sessionEmail = adresse);
    });
  }

  @override
  void dispose() {
    _sessionSub?.cancel();
    super.dispose();
  }

  /// Die anzuzeigende Mailadresse — Sitzung schlaegt Aufruf-Parameter.
  String? get _adresse => _sessionEmail ?? widget.email;

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    // Die Seite selbst zeigt nur die Mailadresse — das Auskunfts-Sheet darunter
    // aber den vollstaendigen Datensatz inklusive Gewicht und Schlaf. Weil das
    // Sheet als Route UEBER dieser hier liegt, bleibt dieser Guard waehrend
    // seiner Anzeige gehalten und deckt ihn mit ab.
    return SecureScreenGuard(
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: ListView(
            key: const ValueKey('screen-settings'),
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 32),
            children: <Widget>[
              const PageHeader(
                large: 'Einstellungen',
                backKey: ValueKey('settings-back'),
              ),
              const SizedBox(height: 16),
              ..._kontoGruppe(t),
              ..._praeferenzenGruppe(),
              ..._datenGruppe(),
              ..._gefahrenzone(t),
              const _VersionFooter(),
            ],
          ),
        ),
      ),
    );
  }

  /// Baut eine [SettingsGroup] nur, wenn sie ueberhaupt Zeilen hat — sonst
  /// stuende eine leere Karte samt Versalien-Beschriftung auf der Seite.
  List<Widget> _gruppe(
    String label,
    List<Widget> kinder, {
    Color? labelColor,
    Color? borderColor,
  }) {
    if (kinder.isEmpty) return const <Widget>[];
    return <Widget>[
      SettingsGroup(
        label: label,
        labelColor: labelColor,
        borderColor: borderColor,
        children: kinder,
      ),
    ];
  }

  // --- KONTO ----------------------------------------------------------------

  List<Widget> _kontoGruppe(AppTokens t) {
    final email = _adresse;
    final repo = widget.authRepository;
    return _gruppe('KONTO', <Widget>[
      if (email != null)
        SettingsRow(
          key: const ValueKey('settings-email'),
          // Rein anzeigend, kein Chevron: geaendert wird sie in der Zeile
          // darunter, und ein „VERIFIED"-Abzeichen kann die App nicht belegen.
          // `accent` statt eines Makro-Tons: die Vorlage nimmt hier ein
          // kraeftiges Blau, das bei uns `protein` waere — und Makro-Farben
          // kodieren ausschliesslich Naehrwerte (DESIGN_REFACTOR §3, Schloss 1).
          // Ein blaues Brief-Icon neben blauen Protein-Balken laese eine
          // Verbindung vermuten, die es nicht gibt.
          leading: IconTile(icon: Icons.mail_outline_rounded, color: t.accent),
          title: 'E-Mail-Adresse',
          subtitle: email,
          chevron: false,
        ),
      if (repo != null)
        SettingsRow(
          key: const ValueKey('settings-change-password'),
          // `accent` statt eines Makro-Tons: die Nährwert-Farben kodieren
          // ausschliesslich Naehrwerte (DESIGN_REFACTOR §3, Schloss 1).
          leading: IconTile(icon: Icons.lock_outline_rounded, color: t.accent),
          title: 'Passwort ändern',
          subtitle: 'Mit Bestätigungs-Code an deine E-Mail',
          onTap: () => _openPasswortAendern(repo, email),
        ),
      // Ohne bekannte Adresse geht der Wechsel nicht: der erste der beiden
      // Codes wird gegen die BISHERIGE Adresse verifiziert.
      if (repo != null && email != null)
        SettingsRow(
          key: const ValueKey('settings-change-email'),
          leading:
              IconTile(icon: Icons.alternate_email_rounded, color: t.accent),
          title: 'E-Mail-Adresse ändern',
          subtitle: 'Bestätigung an die alte und die neue Adresse',
          onTap: () => _openMailAendern(repo, email),
        ),
    ]);
  }

  Future<void> _openPasswortAendern(
    AuthRepository repo,
    String? email,
  ) async {
    final erfolg = await showPasswordChangeSheet(
      context,
      authRepository: repo,
      email: email,
    );
    if (!erfolg || !mounted) return;
    showAppSnack(
      context,
      'Passwort geändert.',
      icon: Icons.lock_reset_rounded,
    );
  }

  Future<void> _openMailAendern(AuthRepository repo, String email) async {
    final erfolg = await showEmailChangeSheet(
      context,
      authRepository: repo,
      currentEmail: email,
    );
    if (!erfolg || !mounted) return;
    // Die neue Adresse steht schon in der Zeile darueber — der Strom hat sie
    // gemeldet, bevor das Sheet zu war.
    showAppSnack(
      context,
      'E-Mail-Adresse geändert.',
      icon: Icons.mark_email_read_rounded,
    );
  }

  // --- PRAEFERENZEN ---------------------------------------------------------

  List<Widget> _praeferenzenGruppe() {
    // Ohne [ThemeModeScope] (Previews, Widget-Tests, die nur diesen Screen
    // pumpen) faellt die Zeile ersatzlos weg — ein Schalter ohne Controller
    // waere ein toter Schalter.
    final controller = ThemeModeScope.maybeOf(context);
    return _gruppe('PRÄFERENZEN', <Widget>[
      if (widget.onOpenGoals != null)
        SettingsRow(
          key: const ValueKey('settings-open-goals'),
          title: 'Profil & Ziele',
          subtitle: 'Körperdaten, Aktivität, Kalorien- und Makroziele',
          onTap: widget.onOpenGoals,
        ),
      if (controller != null)
        SettingsRow(
          // Die Vorlage nennt die Zeile „Dark appearance" und haengt einen
          // Schalter daran. Unsere Auswahl hat DREI Zustaende
          // (DESIGN_REFACTOR §2: Start ist ThemeMode.system) — „Dunkles
          // Erscheinungsbild: Hell" waere ein Widerspruch in einer Zeile. Die
          // Zeile heisst deshalb nach dem, was sie einstellt, nicht nach einem
          // ihrer Werte.
          title: 'Erscheinungsbild',
          subtitle: 'System folgt der Einstellung deines Geräts.',
          chevron: false,
          trailing: SettingsThemeModePill(
            key: const ValueKey('settings-theme-mode'),
            mode: controller.mode,
            // Geraeteeinstellung: sofort persistiert, nichts zu speichern und
            // nichts zu verwerfen.
            onChanged: controller.setMode,
          ),
        ),
    ]);
  }

  // --- DATEN & PRIVATSPHAERE ------------------------------------------------

  List<Widget> _datenGruppe() {
    return _gruppe('DATEN & PRIVATSPHÄRE', <Widget>[
      if (widget.onExportData != null)
        SettingsRow(
          key: const ValueKey('settings-export'),
          title: 'Daten exportieren',
          subtitle: 'Vollständige Kopie als JSON (Art. 15 DSGVO)',
          onTap: _openExport,
        ),
      // Die drei Rechtsseiten. Sie stehen als Zeilen statt als Fusszeile, weil
      // dieser Screen ohnehin aus Zeilen besteht — die Schluessel sind
      // unveraendert die aus [SettingsLegalLinks] (DESIGN_REFACTOR §6).
      const _LegalRow(
        rowKey: ValueKey('settings-privacy-link'),
        title: 'Datenschutz',
        url: kPrivacyUrl,
      ),
      const _LegalRow(
        rowKey: ValueKey('settings-terms-link'),
        title: 'AGB',
        url: kTermsUrl,
      ),
      const _LegalRow(
        rowKey: ValueKey('settings-imprint-link'),
        title: 'Impressum',
        url: kImprintUrl,
      ),
    ]);
  }

  Future<void> _openExport() async {
    final bauen = widget.onExportData;
    if (bauen == null) return;
    await showDataExportSheet(
      context,
      snapshot: bauen,
      vollstaendig: true,
    );
  }

  // --- GEFAHRENZONE ---------------------------------------------------------

  List<Widget> _gefahrenzone(AppTokens t) {
    return _gruppe(
      'GEFAHRENZONE',
      <Widget>[
        if (widget.onSignOut != null)
          SettingsRow(
            key: const ValueKey('settings-sign-out'),
            title: 'Ausloggen',
            onTap: _signOut,
          ),
        if (widget.onDeleteAccount != null) _deleteBlock(t),
      ],
      labelColor: t.danger,
      borderColor: t.danger.withValues(alpha: 0.35),
    );
  }

  Widget _deleteBlock(AppTokens t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              IconTile(icon: Icons.delete_outline_rounded, color: t.danger),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Konto löschen',
                      style: AppType.ui(
                        13.5,
                        weight: FontWeight.w700,
                        color: t.danger,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Entfernt alle Einträge dauerhaft',
                      style: AppType.ui(11.5, color: t.ink2),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Material(
            color: t.danger.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(13),
            child: InkWell(
              key: const ValueKey('settings-delete-account'),
              onTap: _openDeleteSheet,
              borderRadius: BorderRadius.circular(13),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
                child: Text.rich(
                  TextSpan(
                    text: 'Du wirst gebeten, ',
                    children: <InlineSpan>[
                      TextSpan(
                        text: 'LÖSCHEN',
                        style: AppType.ui(
                          11.5,
                          weight: FontWeight.w700,
                          color: t.ink,
                          height: 1.45,
                        ),
                      ),
                      // Die Vorlage verspricht zusaetzlich eine Passwort-
                      // Bestaetigung und „Daten werden nach 30 Tagen
                      // geloescht". Beides waere hier gelogen: die App kann
                      // kein Passwort pruefen (kein AuthRepository auf dieser
                      // Route), und die Loeschung laeuft sofort und
                      // unwiderruflich.
                      const TextSpan(
                        text: ' zu tippen. Danach ist dein Konto samt aller '
                            'Daten sofort und unwiderruflich weg.',
                      ),
                    ],
                    style: AppType.ui(11.5, color: t.ink2, height: 1.45),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Erst die Seite schliessen, dann abmelden.
  ///
  /// Die Reihenfolge ist nicht kosmetisch: `AuthGate` raeumt beim
  /// Identitaetswechsel alles ueber der Root-Route ab und zeigt dann „Deine
  /// Sitzung ist abgelaufen". Wer selbst auf „Ausloggen" getippt hat, soll
  /// diesen Satz nicht sehen — deshalb poppt die gewollte Abmeldung selbst,
  /// bevor sie den Callback ruft (genauso wie im Profil).
  Future<void> _signOut() async {
    final abmelden = widget.onSignOut;
    if (abmelden == null) return;
    final navigator = Navigator.of(context);
    await navigator.maybePop();
    await abmelden();
  }

  Future<void> _openDeleteSheet() async {
    final loeschen = widget.onDeleteAccount;
    if (loeschen == null) return;
    // Die Tipp-Bestaetigung ist die staerkere Absicherung als der
    // Ja/Nein-Dialog im Profil (`confirm-delete-account`): ein Dialog ist mit
    // zwei Taps weg, „LÖSCHEN" tippt niemand versehentlich.
    final bestaetigt =
        await showEatovaSheet<bool>(context, const _DeleteAccountSheet());
    if (bestaetigt != true || !mounted) return;
    final navigator = Navigator.of(context);
    await navigator.maybePop();
    await loeschen();
  }
}

// ---------------------------------------------------------------------------
// Bausteine dieses Screens
// ---------------------------------------------------------------------------

/// Eine Zeile, die eine Rechtsseite im Browser oeffnet.
///
/// Kein Chevron, sondern das Extern-Symbol: der Chevron verspricht eine
/// Folgeseite IN der App, hier verlaesst man sie.
class _LegalRow extends StatelessWidget {
  const _LegalRow({
    required this.rowKey,
    required this.title,
    required this.url,
  });

  final Key rowKey;
  final String title;
  final String url;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return SettingsRow(
      key: rowKey,
      title: title,
      chevron: false,
      trailing: Icon(Icons.open_in_new_rounded, size: 15, color: t.ink2),
      onTap: () => launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      ),
    );
  }
}

/// Die Versionszeile am Seitenfuss.
class _VersionFooter extends StatelessWidget {
  const _VersionFooter();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Center(
      child: FutureBuilder<PackageInfo>(
        future: _packageInfo,
        builder: (context, snapshot) {
          final info = snapshot.data;
          return Text(
            info == null
                ? 'Eatova'
                : 'Version ${info.version} · Build ${info.buildNumber}',
            textAlign: TextAlign.center,
            style: AppType.ui(
              10.5,
              weight: FontWeight.w500,
              // Ohne Zusatz-Transparenz: `ink2` ist bereits der gedaempfte Ton
              // und exakt auf 4.5:1 ausgelegt.
              color: t.ink2,
            ),
          );
        },
      ),
    );
  }
}

/// Die Tipp-Bestaetigung fuer die Kontoloeschung.
///
/// Poppt mit `true`, sobald der Nutzer „LÖSCHEN" getippt und die Aktion
/// ausgeloest hat; sonst mit `null`.
class _DeleteAccountSheet extends StatefulWidget {
  const _DeleteAccountSheet();

  @override
  State<_DeleteAccountSheet> createState() => _DeleteAccountSheetState();
}

class _DeleteAccountSheetState extends State<_DeleteAccountSheet> {
  static const String _wort = 'LÖSCHEN';

  final TextEditingController _confirm = TextEditingController();

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  /// Gross-/Kleinschreibung egal: die Bestaetigung soll vor Versehen schuetzen,
  /// nicht vor der Shift-Taste.
  bool get _scharf => _confirm.text.trim().toUpperCase() == _wort;

  @override
  Widget build(BuildContext context) {
    // Der Scroller sitzt seit 2026-08-10 in [SheetScaffold] selbst — die
    // Ueberlaufgefahr bei grosser Systemschrift betrifft jedes Sheet, nicht
    // nur dieses.
    return SheetScaffold(
      title: 'Konto löschen',
      subtitle: 'Das entfernt dein Profil, alle Mahlzeiten, deinen '
          'Gewichtsverlauf und den Coach-Verlauf. Es lässt sich nicht '
          'rückgängig machen.',
      destructive: true,
      actionLabel: 'Konto endgültig löschen',
      actionEnabled: _scharf,
      onAction: () => Navigator.of(context).pop(true),
      children: <Widget>[
        SheetField(
          key: const ValueKey('settings-delete-confirm-field'),
          label: 'Zum Bestätigen $_wort tippen',
          hint: _wort,
          controller: _confirm,
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }
}
