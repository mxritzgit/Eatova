import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/legal_links.dart';
import '../../app/locale_controller.dart';
import '../../auth/auth_repository.dart';
import '../../l10n/l10n.dart';
import '../../services/secure_screen.dart';
import '../../theme/app_tokens.dart';
import '../../theme/theme_mode_controller.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/design/design.dart';
import '../../widgets/shared/data_export_sheet.dart';
import 'account_change_messages.dart';
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
/// „Über Eatova" (`settings-about`) ist am 2026-08-10 aus dem Profil
/// HIERHER gezogen, als der dortige Block „Daten & Konto" entfiel. Es ist die
/// einzige der sechs Profil-Zeilen ohne Gegenstueck gewesen — und keine
/// Kosmetik: sein Sheet traegt die nach ODbL vorgeschriebene Quellennennung
/// fuer die OpenFoodFacts-Daten UND die Datenschutz-Zeile nach DSGVO Art. 13
/// (erreichbar auch nach dem Login, nicht nur auf dem Auth-Screen). Es steht
/// in DATEN & PRIVATSPHÄRE, weil genau das sein Inhalt ist.
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

  /// Traegt die Konto-Aenderungen (Passwort, Mailadresse) und seit dem Audit
  /// vom 2026-08-14 auch die Re-Authentifizierung vor der Kontoloeschung. Null
  /// in Preview/Tests ohne Auth — die betroffenen Zeilen entfallen dann, statt
  /// ins Leere zu fuehren.
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
/// schlaegt die Future fehl — die Zeilen zeigen dann „—".
///
/// Dieselbe Future existiert nochmal privat in `profile_screen.dart` (fuer die
/// Wortmarke im Profil-Fuss); beide gehoeren in einen gemeinsamen Zugriff
/// (siehe Bericht).
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
    final l10n = context.l10n;

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
              PageHeader(
                large: l10n.settingsPageTitle,
                backKey: const ValueKey('settings-back'),
              ),
              const SizedBox(height: 16),
              ..._kontoGruppe(t, l10n),
              ..._praeferenzenGruppe(l10n),
              ..._datenGruppe(l10n),
              ..._gefahrenzone(t, l10n),
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

  List<Widget> _kontoGruppe(AppTokens t, AppLocalizations l10n) {
    final email = _adresse;
    final repo = widget.authRepository;
    return _gruppe(l10n.settingsGroupAccount, <Widget>[
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
          title: l10n.settingsEmailLabel,
          subtitle: email,
          chevron: false,
        ),
      if (repo != null)
        SettingsRow(
          key: const ValueKey('settings-change-password'),
          // `accent` statt eines Makro-Tons: die Nährwert-Farben kodieren
          // ausschliesslich Naehrwerte (DESIGN_REFACTOR §3, Schloss 1).
          leading: IconTile(icon: Icons.lock_outline_rounded, color: t.accent),
          title: l10n.settingsChangePasswordTitle,
          subtitle: l10n.settingsChangePasswordSubtitle,
          onTap: () => _openPasswortAendern(repo, email),
        ),
      // Ohne bekannte Adresse geht der Wechsel nicht: der erste der beiden
      // Codes wird gegen die BISHERIGE Adresse verifiziert.
      if (repo != null && email != null)
        SettingsRow(
          key: const ValueKey('settings-change-email'),
          leading:
              IconTile(icon: Icons.alternate_email_rounded, color: t.accent),
          title: l10n.settingsChangeEmailTitle,
          subtitle: l10n.settingsChangeEmailSubtitle,
          onTap: () => _openMailAendern(repo, email),
        ),
    ]);
  }

  Future<void> _openPasswortAendern(
    AuthRepository repo,
    String? email,
  ) async {
    final l10n = context.l10n;
    final erfolg = await showPasswordChangeSheet(
      context,
      authRepository: repo,
      email: email,
    );
    if (!erfolg || !mounted) return;
    showAppSnack(
      context,
      l10n.settingsPasswordChangedSnack,
      icon: Icons.lock_reset_rounded,
    );
  }

  Future<void> _openMailAendern(AuthRepository repo, String email) async {
    final l10n = context.l10n;
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
      l10n.settingsEmailChangedSnack,
      icon: Icons.mark_email_read_rounded,
    );
  }

  // --- PRAEFERENZEN ---------------------------------------------------------

  List<Widget> _praeferenzenGruppe(AppLocalizations l10n) {
    // Ohne [ThemeModeScope] (Previews, Widget-Tests, die nur diesen Screen
    // pumpen) faellt die Zeile ersatzlos weg — ein Schalter ohne Controller
    // waere ein toter Schalter.
    final controller = ThemeModeScope.maybeOf(context);
    // Dasselbe Wächter-Muster fuer die Sprachwahl (Spiegel des Anzeige-Modus,
    // s.o.): ohne [LocaleScope] gibt es nichts, das den Override setzen
    // koennte.
    final localeController = LocaleScope.maybeOf(context);
    return _gruppe(l10n.settingsGroupPreferences, <Widget>[
      if (widget.onOpenGoals != null)
        SettingsRow(
          key: const ValueKey('settings-open-goals'),
          title: l10n.goalsPageTitle,
          subtitle: l10n.settingsOpenGoalsSubtitle,
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
          title: l10n.settingsAppearanceTitle,
          subtitle: l10n.settingsAppearanceSubtitle,
          chevron: false,
          trailing: SettingsThemeModePill(
            key: const ValueKey('settings-theme-mode'),
            mode: controller.mode,
            // Geraeteeinstellung: sofort persistiert, nichts zu speichern und
            // nichts zu verwerfen.
            onChanged: controller.setMode,
          ),
        ),
      if (localeController != null)
        SettingsRow(
          title: l10n.settingsLanguageTitle,
          subtitle: l10n.settingsLanguageSubtitle,
          chevron: false,
          trailing: SettingsLanguagePill(
            key: const ValueKey('settings-language'),
            value: localeController.override,
            // Geraeteeinstellung: sofort persistiert, nichts zu verwerfen.
            onChanged: localeController.setOverride,
          ),
        ),
    ]);
  }

  // --- DATEN & PRIVATSPHAERE ------------------------------------------------

  List<Widget> _datenGruppe(AppLocalizations l10n) {
    return _gruppe(l10n.settingsGroupDataPrivacy, <Widget>[
      if (widget.onExportData != null)
        SettingsRow(
          key: const ValueKey('settings-export'),
          title: l10n.settingsExportDataTitle,
          subtitle: l10n.settingsExportDataSubtitle,
          onTap: _openExport,
        ),
      // Die drei Rechtsseiten. Sie stehen als Zeilen statt als Fusszeile, weil
      // dieser Screen ohnehin aus Zeilen besteht — die Schluessel sind
      // unveraendert die aus [SettingsLegalLinks] (DESIGN_REFACTOR §6).
      _LegalRow(
        rowKey: const ValueKey('settings-privacy-link'),
        title: l10n.settingsLegalPrivacy,
        url: kPrivacyUrl,
      ),
      _LegalRow(
        rowKey: const ValueKey('settings-terms-link'),
        title: l10n.settingsLegalTerms,
        url: kTermsUrl,
      ),
      _LegalRow(
        rowKey: const ValueKey('settings-imprint-link'),
        title: l10n.settingsLegalImprint,
        url: kImprintUrl,
      ),
      // Version, Herkunft der Daten (ODbL-Namensnennung fuer OpenFoodFacts)
      // und der Datenschutz-Link. Steht bewusst in DIESER Gruppe und nicht in
      // einer eigenen: der Sheet-Inhalt ist von der ersten bis zur letzten
      // Zeile eine Auskunft ueber Daten.
      SettingsRow(
        key: const ValueKey('settings-about'),
        title: l10n.settingsAboutTitle,
        subtitle: l10n.settingsAboutSubtitle,
        onTap: () => showEatovaSheet<void>(context, const _AboutSheet()),
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

  List<Widget> _gefahrenzone(AppTokens t, AppLocalizations l10n) {
    final repo = widget.authRepository;
    final email = _adresse;
    return _gruppe(
      l10n.settingsGroupDangerZone,
      <Widget>[
        if (widget.onSignOut != null)
          SettingsRow(
            key: const ValueKey('settings-sign-out'),
            title: l10n.settingsSignOutTitle,
            onTap: _signOut,
          ),
        // Ohne Auth-Schicht ODER ohne bekannte Adresse gibt es nichts, wogegen
        // sich der Nutzer erneut ausweisen koennte — und dann entfaellt die
        // Zeile ersatzlos, statt die unwiderrufliche Aktion ohne zweite Huerde
        // anzubieten (dieselbe Regel wie fuer Passwort- und Adresswechsel).
        if (widget.onDeleteAccount != null && repo != null && email != null)
          _deleteBlock(t, l10n, repo, email),
      ],
      labelColor: t.danger,
      borderColor: t.danger.withValues(alpha: 0.35),
    );
  }

  Widget _deleteBlock(
    AppTokens t,
    AppLocalizations l10n,
    AuthRepository repo,
    String email,
  ) {
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
                      l10n.settingsDeleteAccountTitle,
                      style: AppType.ui(
                        13.5,
                        weight: FontWeight.w700,
                        color: t.danger,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.settingsDeleteAccountBlockSubtitle,
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
              onTap: () => _openDeleteSheet(repo, email),
              borderRadius: BorderRadius.circular(13),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
                child: Text.rich(
                  TextSpan(
                    text: l10n.settingsDeleteAccountPromptPrefix,
                    children: <InlineSpan>[
                      TextSpan(
                        text: l10n.settingsDeleteConfirmWord,
                        style: AppType.ui(
                          11.5,
                          weight: FontWeight.w700,
                          color: t.ink,
                          height: 1.45,
                        ),
                      ),
                      // Die Vorlage verspricht zusaetzlich eine Bestaetigung
                      // der Identitaet und „Daten werden nach 30 Tagen
                      // geloescht". Das Erste gibt es seit dem Sicherheits-
                      // Audit vom 2026-08-14 wirklich (zweiter Schritt mit
                      // Mail-Code, [_DeleteAccountSheet]) und der Satz nennt
                      // es. Das Zweite bleibt gelogen: die Loeschung laeuft
                      // sofort und unwiderruflich, es gibt keine Frist.
                      TextSpan(
                        text: l10n.settingsDeleteAccountPromptSuffixCode,
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

  Future<void> _openDeleteSheet(AuthRepository repo, String email) async {
    final loeschen = widget.onDeleteAccount;
    if (loeschen == null) return;
    // Zwei verschiedene Huerden, weil sie zwei verschiedene Faelle abfangen:
    // das getippte Wort das Versehen (ein Ja/Nein-Dialog wie im Profil ist mit
    // zwei Taps weg), der Mail-Code den fremden Finger am entsperrten Geraet.
    // Der zweite Teil ist seit dem Audit vom 2026-08-14 Pflicht: `delete_
    // account()` prueft serverseitig nur `auth.uid()` und alles haengt per
    // `on delete cascade` daran — die Hemmschwelle liegt vollstaendig hier.
    final bestaetigt = await showEatovaSheet<bool>(
      context,
      _DeleteAccountSheet(
        key: const ValueKey<String>('delete-account-sheet'),
        authRepository: repo,
        email: email,
      ),
    );
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

/// Das „Über Eatova"-Sheet.
///
/// Bis 2026-08-10 privat in `profile_screen.dart` (Zeile `profile-action-about`
/// im entfallenen Block „Daten & Konto"). Mit umgezogen sind [_AboutRow] und
/// [_PrivacyLinkRow] — und mit ihnen der Testschluessel
/// `profile-privacy-link`, der bewusst NICHT umbenannt wurde
/// (DESIGN_REFACTOR §6: „Key bleibt Key, der Key wandert mit").
///
/// Zwei Zeilen darin sind Pflicht, nicht Deko:
///  * **Quellen** — die Namensnennung fuer die OpenFoodFacts-Daten (ODbL).
///  * **Datenschutzerklärung** — DSGVO Art. 13 verlangt sie auch NACH dem
///    Login, nicht nur auf dem Auth-Screen.
///
/// Die Fusszeile „Version … · Build …" der Einstellungen ist mit diesem Umzug
/// entfallen: sie stand ab dann drei Zeilen unter einem Eintrag, der dasselbe
/// noch einmal sagt. Ohne Tipp bleibt die Version im Profil-Fuss ablesbar
/// (`Eatova · v1.2.3`).
class _AboutSheet extends StatelessWidget {
  const _AboutSheet();

  /// Datenquellen ehrlich + plattformgerecht: Produktdaten kommen aus
  /// OpenFoodFacts bzw. dem eigenen Suchindex; Schritte liefert Apple Health
  /// (nur iOS — auf Android ist der Health-Pfad ein No-op, also dort nicht
  /// nennen). "wger" war nie angebunden und ist raus.
  static String _sources(AppLocalizations l10n) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return l10n.settingsAboutSourcesWithAppleHealth;
    }
    return l10n.settingsAboutSourcesDefault;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    // Scrollbar statt starr: bei doppelter Systemschrift ist der Block aus
    // Beschreibung, Version, Build, Quellen und Datenschutz-Zeile hoeher als
    // der Bildschirm (gemessen: 251 px Ueberlauf). Der Datenschutz-Link steht
    // ganz unten — genau der Teil, der nie abgeschnitten werden darf.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              IconTile(
                icon: Icons.bolt_rounded,
                color: t.accent,
                size: 44,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      l10n.settingsAboutAppName,
                      style: AppType.display(20, color: t.ink),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.settingsAboutTagline,
                      style: AppType.ui(
                        12,
                        weight: FontWeight.w500,
                        color: t.ink2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            l10n.settingsAboutDescription,
            style: AppType.ui(13, color: t.ink2, height: 1.45),
          ),
          const SizedBox(height: 16),
          FutureBuilder<PackageInfo>(
            future: _packageInfo,
            builder: (context, snapshot) {
              final info = snapshot.data;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _AboutRow(
                    label: l10n.settingsAboutVersionLabel,
                    value: info?.version ?? '—',
                  ),
                  const SizedBox(height: 6),
                  _AboutRow(
                    label: l10n.settingsAboutBuildLabel,
                    value: info?.buildNumber ?? '—',
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 6),
          _AboutRow(
            label: l10n.settingsAboutSourcesLabel,
            value: _sources(l10n),
          ),
          const SizedBox(height: 14),
          // DSGVO Art. 13 / App-Store: Datenschutz auch nach dem Login
          // erreichbar, nicht nur auf dem Auth-Screen.
          const _PrivacyLinkRow(),
        ],
      ),
    );
  }
}

/// Tappbare Datenschutz-Zeile im [_AboutSheet]. Oeffnet die Policy extern
/// (url_launcher).
///
/// Der Schluessel heisst weiterhin `profile-privacy-link` — er ist mit dem
/// Sheet aus dem Profil mitgewandert (DESIGN_REFACTOR §6). Die Zeile
/// `settings-privacy-link` eine Ebene darueber ist ein ANDERES Bedienelement
/// (Gruppe DATEN & PRIVATSPHÄRE) und bleibt davon unberuehrt.
class _PrivacyLinkRow extends StatelessWidget {
  const _PrivacyLinkRow();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return InkWell(
      key: const ValueKey('profile-privacy-link'),
      onTap: () => launchUrl(
        Uri.parse(kPrivacyUrl),
        mode: LaunchMode.externalApplication,
      ),
      borderRadius: BorderRadius.circular(rControl),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: t.surf,
          borderRadius: BorderRadius.circular(rControl),
          border: Border.all(color: t.line),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.shield_outlined, color: t.ink2, size: 16),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                context.l10n.settingsPrivacyPolicyLinkLabel,
                style: AppType.ui(13, weight: FontWeight.w600, color: t.ink),
              ),
            ),
            Icon(Icons.open_in_new_rounded, color: t.ink2, size: 15),
          ],
        ),
      ),
    );
  }
}

/// Beschriftung links, Wert rechts — die Zeilenform des [_AboutSheet].
class _AboutRow extends StatelessWidget {
  const _AboutRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      children: <Widget>[
        Text(
          label,
          style: AppType.ui(12, weight: FontWeight.w500, color: t.ink2),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: AppType.ui(12, weight: FontWeight.w600, color: t.ink),
          ),
        ),
      ],
    );
  }
}

enum _LoeschSchritt { wort, code }

/// Die zweistufige Bestaetigung fuer die Kontoloeschung.
///
/// Poppt mit `true`, sobald der Nutzer „LÖSCHEN" getippt UND den Code aus
/// seinem Postfach bestaetigt hat; sonst mit `null`.
///
/// WARUM DER ZWEITE SCHRITT (Sicherheits-Audit 2026-08-14)
/// Bis dahin genuegte das getippte Wort — das direkt daneben als Hinweistext
/// stand. Damit war die einzige unwiderrufliche Aktion der App schwaecher
/// gesichert als der Passwortwechsel daneben, der einen Mail-Code verlangt:
/// zwanzig Sekunden am entsperrten Telefon loeschten Profil, Tagebuch,
/// Gewicht, Coach-Verlauf und Rezepte. Beide Schritte leben wie in
/// `account_change_sheets.dart` im SELBEN Sheet: der zweite braucht den ersten,
/// und ein Sheet, das sich schliesst und sofort wieder oeffnet, sieht aus wie
/// ein Fehler.
///
/// WARUM DER RECOVERY-CODE UND NICHT `startPasswordChange()`
/// Semantisch waere die Reauth-Mail von GoTrue (`reauthenticate()`) die
/// passendere: sie sagt genau „bestaetige diese Aktion". Ihre Nonce laesst sich
/// aber ausschliesslich ZUSAMMEN mit einem neuen Passwort einloesen
/// ([AuthRepository.confirmPasswordChange]) — es gibt keinen Weg, sie allein
/// pruefen zu lassen, und heimlich das Passwort zu tauschen kommt nicht in
/// Frage. [AuthRepository.sendPasswordReset] + [AuthRepository.verifyRecoveryCode]
/// ist deshalb das einzige vorhandene Paar, bei dem der SERVER den Code
/// wirklich prueft. Eine Bestaetigung, die die App selbst „abnickt", waere
/// Theater.
class _DeleteAccountSheet extends StatefulWidget {
  const _DeleteAccountSheet({
    super.key,
    required this.authRepository,
    required this.email,
  });

  final AuthRepository authRepository;

  /// Die Adresse, an die der Code geht — Pflicht, weil er gegen genau sie
  /// verifiziert wird.
  final String email;

  @override
  State<_DeleteAccountSheet> createState() => _DeleteAccountSheetState();
}

class _DeleteAccountSheetState extends State<_DeleteAccountSheet> {
  final TextEditingController _confirm = TextEditingController();
  final TextEditingController _code = TextEditingController();

  _LoeschSchritt _schritt = _LoeschSchritt.wort;
  bool _busy = false;
  String? _fehler;
  String? _codeFehler;

  @override
  void dispose() {
    _confirm.dispose();
    _code.dispose();
    super.dispose();
  }

  /// Gross-/Kleinschreibung egal: die Bestaetigung soll vor Versehen schuetzen,
  /// nicht vor der Shift-Taste. Das erwartete Wort kommt aus der ARB (unter
  /// `en` „DELETE" statt „LÖSCHEN") — deshalb ein Getter mit Context statt
  /// einer `static const`.
  bool _scharf(String wort) => _confirm.text.trim().toUpperCase() == wort;

  Future<void> _codeAnfordern(String wort) async {
    // Der Doppel-Tap-Riegel liegt hier UND an `actionEnabled`: die Sperre am
    // Knopf greift erst mit dem naechsten Frame. Ein zweiter Mailversand
    // liefe ausserdem in die GoTrue-Drosselung und verbraenne den ersten Code.
    if (_busy || !_scharf(wort)) return;
    setState(() {
      _busy = true;
      _fehler = null;
    });
    try {
      await widget.authRepository.sendPasswordReset(widget.email);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _fehler = accountChangeErrorMessage(error, context.l10n);
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _schritt = _LoeschSchritt.code;
    });
  }

  Future<void> _loeschenBestaetigen() async {
    if (_busy) return;
    final l10n = context.l10n;
    final code = _code.text.trim();
    // Was die App selbst wissen kann, faengt sie hier ab: ein zu kurzer Code
    // laeuft absehbar in einen Serverfehler und ist danach verbrannt.
    if (!isAccountCode(code)) {
      setState(() {
        _fehler = null;
        _codeFehler = kAccountCodeInvalid(l10n);
      });
      return;
    }

    setState(() {
      _busy = true;
      _fehler = null;
      _codeFehler = null;
    });
    try {
      await widget.authRepository
          .verifyRecoveryCode(email: widget.email, code: code);
    } catch (error) {
      if (!mounted) return;
      // Kein Zuruecksetzen des Feldes: wer sich vertippt, soll korrigieren
      // koennen statt neu anzufangen.
      setState(() {
        _busy = false;
        _fehler = accountChangeErrorMessage(error, context.l10n);
      });
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final wort = l10n.settingsDeleteConfirmWord;
    final ersterSchritt = _schritt == _LoeschSchritt.wort;
    // Der Scroller sitzt seit 2026-08-10 in [SheetScaffold] selbst — die
    // Ueberlaufgefahr bei grosser Systemschrift betrifft jedes Sheet, nicht
    // nur dieses.
    return SheetScaffold(
      title: l10n.settingsDeleteAccountTitle,
      subtitle: ersterSchritt
          ? l10n.settingsDeleteAccountSheetSubtitle
          : l10n.settingsDeleteAccountCodeSentTo(widget.email),
      destructive: true,
      actionLabel: _aktionsBeschriftung(l10n, ersterSchritt),
      actionEnabled: ersterSchritt ? !_busy && _scharf(wort) : !_busy,
      onAction:
          ersterSchritt ? () => _codeAnfordern(wort) : _loeschenBestaetigen,
      children: <Widget>[
        if (ersterSchritt)
          SheetField(
            key: const ValueKey('settings-delete-confirm-field'),
            label: l10n.settingsDeleteAccountFieldLabel(wort),
            hint: wort,
            controller: _confirm,
            enabled: !_busy,
            onChanged: (_) => setState(() {}),
          )
        else
          SheetField(
            key: const ValueKey('settings-delete-code-field'),
            label: l10n.settingsDeleteAccountCodeFieldLabel,
            hint: '••••••',
            controller: _code,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            errorText: _codeFehler,
          ),
        if (_fehler != null)
          SettingsNote(
            key: const ValueKey('settings-delete-error'),
            _fehler!,
            tone: context.t.danger,
            icon: Icons.error_outline_rounded,
            boxed: true,
          ),
      ],
    );
  }

  String _aktionsBeschriftung(AppLocalizations l10n, bool ersterSchritt) {
    if (_busy) {
      return ersterSchritt
          ? l10n.settingsDeleteAccountRequestingCta
          : l10n.settingsDeleteAccountCheckingCta;
    }
    // Der Loesch-Knopf traegt seine Beschriftung erst im ZWEITEN Schritt: im
    // ersten loescht er nichts, er fordert den Code an.
    return ersterSchritt
        ? l10n.settingsDeleteAccountRequestCta
        : l10n.settingsDeleteAccountActionLabel;
  }
}
