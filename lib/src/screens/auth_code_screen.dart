import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/auth_repository.dart';
import '../l10n/l10n.dart';
import '../services/local_cache.dart'
    show KeyValueStore, SharedPreferencesStore;
import '../services/secure_screen.dart';
import '../theme/app_colors.dart';
import '../widgets/common/app_snack.dart';

/// Welcher Code-Flow laeuft: Passwort-Reset oder Registrierungs-Bestaetigung.
enum AuthCodeFlow { recovery, signup }

/// Grobe Klassifizierung eines Auth-Fehlers — reicht fuer die drei Saetze,
/// die diese Seite zeigt.
enum _AuthErrorKind { rateLimited, codeRejected, unknown }

/// Reihenfolge wie in `settings/account_change_messages.dart`: erst das
/// Drossel-Limit, dann der abgelehnte Code. GoTrue drosselt den Mailversand
/// hart („For security purposes, you can only request this after 51 seconds");
/// diese Meldung darf NICHT im Sammelzweig landen, der zum naechsten Versuch
/// auffordert — genau das erzeugt die Tap-Schleife, die das Kontingent
/// leerlaufen laesst.
_AuthErrorKind _classifyAuthError(Object error) {
  final raw = error.toString().toLowerCase();
  if (raw.contains('rate limit') ||
      raw.contains('rate_limit') ||
      raw.contains('too many') ||
      raw.contains('for security purposes')) {
    return _AuthErrorKind.rateLimited;
  }
  if (raw.contains('expired') || raw.contains('invalid')) {
    return _AuthErrorKind.codeRejected;
  }
  return _AuthErrorKind.unknown;
}

/// Stand des Riegels fuer EINE Adresse.
class _ThrottleState {
  const _ThrottleState({this.lastSent, this.failedAttempts = 0});

  final DateTime? lastSent;
  final int failedAttempts;
}

/// Persistenter, an die ADRESSE gebundener Riegel fuer den Code-Versand
/// (Audit 2026-08-14).
///
/// `sendPasswordReset` schickt eine Mail an eine BELIEBIGE eingetippte
/// Adresse. Ein Riegel, der nur an der Screen-Instanz haengt, ist deshalb
/// keiner: wer die Seite verlaesst und neu oeffnet, faengt sonst bei null an —
/// das Postfach eines Fremden laesst sich fluten, das GoTrue-Stundenkontingent
/// laeuft leer (danach bekommt KEIN Nutzer mehr Mails) und jede Zustellung
/// kostet den eigenen Mailserver. Der Zeitstempel liegt darum im
/// Geraetespeicher, geschluesselt ueber die Adresse.
///
/// Der Schluessel traegt einen FNV-1a-Digest der normalisierten Adresse statt
/// ihres Klartexts: die Prefs sollen keine Liste der hier eingetippten
/// (womoeglich fremden) Adressen zurueckhalten. Der Digest muss nur stabil
/// ueber Neustarts und kollisionsarm sein, nicht kryptografisch — das spart
/// eine Dependency.
///
/// Der Speicher traegt die HALTBARKEIT des Riegels ueber Neustarts hinweg —
/// er ist nicht seine Bedingung. Antwortet er nicht (kein Plugin-Channel,
/// langsames Geraet), laeuft der Versand trotzdem: [_AuthCodeScreenState]
/// wartet auf keinen Lese- oder Schreibvorgang, sondern liest vorab (beim
/// Tippen) und schreibt nebenher. Frueher hing der Knopf an diesen Futures —
/// blieb einer offen, ging KEINE Mail mehr raus und der Spinner drehte
/// weiter: fail-closed statt des hier beschriebenen fail-open. Der Riegel
/// innerhalb der Sitzung gilt darum immer, der serverseitige GoTrue-Riegel
/// bleibt der Rueckfall.
///
/// ACHTUNG (Kommentar-Ehrlichkeit): der Riegel ist bewusst FAIL-OPEN (s.o.)
/// und rein CLIENTSEITIG — er lebt nur in diesem Widget-Zustand und im
/// lokalen Geraetespeicher. Ein eigener Client (curl, ein zweites Geraet,
/// eine gepatchte App) umgeht ihn trivial, [maxAttempts] eingeschlossen: er
/// zaehlt schlicht keine Fehlversuche mehr mit. Als KOSTEN- und
/// MISSBRAUCHSBREMSE fuer den gutartigen Fall (diese App, dieses Geraet)
/// taugt er; als BRUTE-FORCE-SCHUTZ fuer den 6-stelligen Code NICHT. Der
/// echte Schutz muss serverseitig kommen (GoTrue-Rate-Limits, Code-Ablauf
/// nach mailer_otp_exp, ggf. IP-Sperren).
class _OtpSendThrottle {
  _OtpSendThrottle(this._injected);

  static const Duration cooldown = Duration(seconds: 60);
  static const int maxAttempts = 5;
  static const String storagePrefix = 'eatova.v1.otp_guard.';

  final KeyValueStore? _injected;

  /// Die EINE laufende Aufloesung. Ohne diesen Cache startete jeder Lese- und
  /// Schreibvorgang ein weiteres `SharedPreferences.getInstance()`, solange
  /// das erste noch offen war.
  Future<KeyValueStore?>? _resolving;

  Future<KeyValueStore?> _store() {
    final injiziert = _injected;
    if (injiziert != null) return Future<KeyValueStore?>.value(injiziert);
    return _resolving ??= _resolve();
  }

  Future<KeyValueStore?> _resolve() async {
    try {
      return await SharedPreferencesStore.create();
    } catch (_) {
      // Prefs nicht verfuegbar: s. Klassen-Kommentar (fail-open).
      return null;
    }
  }

  static String _key(String email) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(email.trim().toLowerCase())) {
      hash = (hash ^ byte) & 0xFFFFFFFF;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return '$storagePrefix${hash.toRadixString(16)}';
  }

  Future<_ThrottleState> read(String email) async {
    final store = await _store();
    if (store == null) return const _ThrottleState();
    final key = _key(email);
    try {
      final roh = await store.getString(key);
      if (roh == null) return const _ThrottleState();
      final map = jsonDecode(roh) as Map<String, dynamic>;
      final gesendet = map['sent'];
      final fehl = map['failed'];
      final stand = _ThrottleState(
        lastSent: gesendet is int
            ? DateTime.fromMillisecondsSinceEpoch(gesendet)
            : null,
        failedAttempts: fehl is int && fehl > 0 ? fehl : 0,
      );
      // Aufraeumen statt liegenlassen (W3c): die Schluessel `otp_guard.<hash>`
      // sammeln sich sonst unbegrenzt an, weil hier nie geloescht wird. Kein
      // eigener Hintergrundjob noetig — es reicht, beim ohnehin faelligen
      // Lesen mit aufzuraeumen.
      if (_expired(stand)) {
        unawaited(store.remove(key));
        return const _ThrottleState();
      }
      return stand;
    } catch (_) {
      // Kaputter Eintrag darf den Flow nicht blockieren.
      return const _ThrottleState();
    }
  }

  /// `true`, wenn [stand] keine Wirkung mehr hat und der Eintrag darum
  /// geraeumt werden darf.
  ///
  /// Eine aktive Sperre (>= [maxAttempts] Fehlversuche) verfaellt NICHT von
  /// selbst — sie gilt bis zu einem echten neuen Versand ([_stamp] mit
  /// `resetAttempts: true`) und darf durchs Aufraeumen nicht heimlich
  /// aufgehoben werden. Nur wenn der Cooldown seit [_ThrottleState.lastSent]
  /// laengst verstrichen ist UND keine Sperre greift, traegt der Eintrag
  /// nichts mehr bei.
  bool _expired(_ThrottleState stand) {
    if (stand.failedAttempts >= maxAttempts) return false;
    final start = stand.lastSent;
    if (start == null) return false;
    return clock.now().difference(start) >= cooldown;
  }

  /// `true`, wenn der Stand wirklich weggeschrieben wurde.
  Future<bool> write(String email, _ThrottleState state) async {
    final store = await _store();
    if (store == null) return false;
    try {
      await store.setString(
        _key(email),
        jsonEncode(<String, dynamic>{
          'sent': state.lastSent?.millisecondsSinceEpoch,
          'failed': state.failedAttempts,
        }),
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Eigene Seite fuer die 6-stelligen E-Mail-Codes (OTP statt Mail-Link).
///
///  * [AuthCodeFlow.recovery]: E-Mail eingeben -> Code anfordern -> Code
///    pruefen (verifyOTP recovery, stellt die Session her) -> neues Passwort
///    setzen. Die Versand-Bestaetigung bleibt NEUTRAL — ob zur Adresse ein
///    Konto existiert (oder ein reines Google-Konto), verraet die App nicht.
///  * [AuthCodeFlow.signup]: die Adresse steht fest (frisch registriert),
///    nur der Code wird geprueft; der AuthGate wechselt danach von selbst
///    auf die Home-Page (Session-Stream).
///
/// Die Codes sind serverseitig 10 Minuten gueltig (mailer_otp_exp).
class AuthCodeScreen extends StatefulWidget {
  const AuthCodeScreen({
    super.key,
    required this.authRepository,
    required this.flow,
    this.initialEmail = '',
    this.throttleStore,
  });

  final AuthRepository authRepository;
  final AuthCodeFlow flow;
  final String initialEmail;

  /// Ersetzt SharedPreferences als Ablage des Versand-Riegels — gedacht fuer
  /// Tests, die den Cooldown ohne Plugin-Channel nachstellen
  /// (`InMemoryKeyValueStore`, Muster `LocalCache`).
  final KeyValueStore? throttleStore;

  @override
  State<AuthCodeScreen> createState() => _AuthCodeScreenState();
}

/// Schritte des Recovery-Flows; Signup startet direkt beim Code.
enum _Step { email, code, password }

class _AuthCodeScreenState extends State<AuthCodeScreen> {
  late final TextEditingController _email =
      TextEditingController(text: widget.initialEmail);
  final TextEditingController _code = TextEditingController();
  final TextEditingController _password = TextEditingController();

  late _Step _step =
      widget.flow == AuthCodeFlow.signup ? _Step.code : _Step.email;
  bool _busy = false;
  bool _passwordVisible = false;
  String? _error;
  String? _message;

  late final _OtpSendThrottle _throttle =
      _OtpSendThrottle(widget.throttleStore);
  DateTime? _lastSent;
  int _failedAttempts = 0;
  int _cooldownSeconds = 0;
  Timer? _ticker;

  /// Adresse, zu der [_lastSent] und [_failedAttempts] gerade gehoeren —
  /// zugleich das Marken-Token gegen spaet eintreffende Lesevorgaenge.
  String? _guardFor;

  /// `true`, sobald diese Sitzung fuer [_guardFor] selbst gestempelt oder
  /// gezaehlt hat. Ein danach eintreffender Lesevorgang ist aelter als der
  /// Stand im Screen und darf ihn nicht zurueckdrehen.
  bool _guardTouched = false;

  bool get _isRecovery => widget.flow == AuthCodeFlow.recovery;

  /// Die Adresse, an der Riegel und Fehlversuchszaehler haengen. Ab dem
  /// Code-Schritt ist das Feld nicht mehr sichtbar, der Wert also stabil.
  String get _guardEmail => _email.text.trim();

  /// Speicher und Riegel muessen dieselbe Adresse meinen — gleiche
  /// Normalisierung wie [_OtpSendThrottle._key].
  static String _normalisiert(String email) => email.trim().toLowerCase();

  bool get _locked => _failedAttempts >= _OtpSendThrottle.maxAttempts;

  /// Die Auth-Seiten stehen noch aus der i18n-Migration (docs/I18N_PAKETE.md)
  /// und werden in Bestandstests OHNE Localizations-Delegates gepumpt —
  /// `context.l10n` wuerde dort werfen. Die NEUEN Texte dieses Audits kommen
  /// trotzdem aus dem ARB, deshalb derselbe Deutsch-Default wie in
  /// `sync_error_messages.dart`.
  AppLocalizations get _l10n =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ?? deL10n;

  @override
  void initState() {
    super.initState();
    _email.addListener(_onEmailChanged);
    unawaited(_hydrate(widget.initialEmail));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _email.removeListener(_onEmailChanged);
    _email.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Holt Stempel und Fehlversuchszaehler aus dem Speicher. Laeuft beim Aufbau
  /// der Seite und bei jeder Adress-Aenderung — nur so ueberlebt der Riegel das
  /// Wegnavigieren, den Rebuild und den Neustart.
  ///
  /// Bewusst NICHT auf dem Weg zum Versand: der Tap auf „Code anfordern" darf
  /// nie auf den Geraetespeicher warten (s. [_OtpSendThrottle]). Steht der
  /// Stand noch aus, gilt der Riegel eben nicht — fail-open.
  Future<void> _hydrate(String email) async {
    final ziel = _normalisiert(email);
    if (ziel.isEmpty) return;
    _guardFor = ziel;
    final stand = await _throttle.read(ziel);
    // Inzwischen eine andere Adresse — oder wir wissen es selbst besser?
    if (!mounted || _guardFor != ziel || _guardTouched) return;
    setState(() {
      _lastSent = stand.lastSent;
      _failedAttempts = stand.failedAttempts;
      _cooldownSeconds = _remainingSeconds();
    });
    _syncTicker();
  }

  /// Der Riegel haengt an der ADRESSE: was fuer die vorige galt, gilt fuer eine
  /// neu getippte nicht. Der Speicher wird deshalb schon beim Tippen gelesen —
  /// bis zum Tap auf den Knopf ist der Stand da, ohne dass der Tap wartet.
  void _onEmailChanged() {
    final ziel = _normalisiert(_email.text);
    if (ziel == _guardFor) return;
    setState(() {
      _guardFor = null;
      _guardTouched = false;
      _lastSent = null;
      _failedAttempts = 0;
      _cooldownSeconds = 0;
    });
    _syncTicker();
    unawaited(_hydrate(ziel));
  }

  int _remainingSeconds() {
    final start = _lastSent;
    if (start == null) return 0;
    final rest = _OtpSendThrottle.cooldown - clock.now().difference(start);
    // Nach UNTEN klemmt `isNegative` (Cooldown laengst vorbei). Nach OBEN
    // braucht es dieselbe Klemme: ein Rest, der die Cooldown-Dauer selbst
    // uebersteigt, ist per Definition unmoeglich (`start` liegt dann in der
    // "Zukunft" relativ zu `clock.now()`) und bedeutet eine zurueckgestellte
    // Geraeteuhr oder einen Zeitzonenwechsel — nicht einen echten, noch
    // laengeren Cooldown. Ohne diese Klemme entstuende ein persistenter
    // Selbst-DoS ("naechster Code in 86400 s"), aus dem der Nutzer nicht mehr
    // herauskaeme (W3b).
    if (rest.isNegative || rest > _OtpSendThrottle.cooldown) return 0;
    return (rest.inMilliseconds / 1000).ceil();
  }

  void _syncTicker() {
    if (_cooldownSeconds <= 0) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    final rest = _remainingSeconds();
    // Ohne sichtbare Aenderung kein Rebuild.
    if (rest == _cooldownSeconds) return;
    setState(() => _cooldownSeconds = rest);
    if (rest <= 0) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  /// Stempelt den Versand. Der Riegel gilt SOFORT; das Wegschreiben laeuft
  /// nebenher und macht ihn nur haltbar (s. [_OtpSendThrottle]).
  /// [resetAttempts] gilt fuer echte Versande — ein neuer Code macht die alten
  /// Fehlversuche gegenstandslos.
  void _stamp(String email, {required bool resetAttempts}) {
    final jetzt = clock.now();
    final versuche = resetAttempts ? 0 : _failedAttempts;
    _guardTouched = true;
    unawaited(_throttle.write(
      email,
      _ThrottleState(lastSent: jetzt, failedAttempts: versuche),
    ));
    if (!mounted) return;
    setState(() {
      _guardFor = _normalisiert(email);
      _lastSent = jetzt;
      _failedAttempts = versuche;
      _cooldownSeconds = _remainingSeconds();
    });
    _syncTicker();
  }

  /// Wie [_stamp] ohne Warten auf den Speicher: der Zaehler kostet niemanden
  /// eine Mail, er sperrt nur die Eingabe, bis ein neuer Code da ist.
  void _countFailedAttempt(String email) {
    final naechster = _failedAttempts + 1;
    _guardTouched = true;
    unawaited(_throttle.write(
      email,
      _ThrottleState(lastSent: _lastSent, failedAttempts: naechster),
    ));
    if (!mounted) return;
    setState(() => _failedAttempts = naechster);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendlyError(Object error) {
    switch (_classifyAuthError(error)) {
      case _AuthErrorKind.rateLimited:
        return _l10n.authCodeRateLimited;
      case _AuthErrorKind.codeRejected:
        return 'Der Code stimmt nicht oder ist abgelaufen. Fordere unten '
            'einfach einen neuen an.';
      case _AuthErrorKind.unknown:
        return 'Das hat gerade nicht geklappt. Bitte nochmal versuchen.';
    }
  }

  /// Faengt die Drossel-Meldung des Servers ab: sie stempelt den Riegel
  /// ebenfalls, damit der Countdown zeigt, wann es weitergeht, statt dass der
  /// Nutzer blind weitertippt.
  Future<void> _sendGuarded(
    String email,
    Future<void> Function() versand,
  ) async {
    try {
      await versand();
    } catch (error) {
      if (_classifyAuthError(error) == _AuthErrorKind.rateLimited) {
        _stamp(email, resetAttempts: false);
      }
      rethrow;
    }
    _stamp(email, resetAttempts: true);
  }

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _error = 'Bitte gib eine gültige E-Mail ein.');
      return;
    }
    // Der Stand FUER DIESE Adresse kam beim Tippen (_onEmailChanged); hier
    // wird nur noch gelesen, was schon da ist. Ein Warten auf den Speicher
    // wuerde den allerersten Versand aufhalten — genau das darf nie passieren.
    final rest = _remainingSeconds();
    if (rest > 0) {
      setState(() => _error = _l10n.authCodeThrottleWait(rest));
      return;
    }
    await _run(() async {
      await _sendGuarded(
          email, () => widget.authRepository.sendPasswordReset(email));
      if (!mounted) return;
      setState(() {
        _step = _Step.code;
        _message = 'Falls ein Konto mit dieser E-Mail existiert, ist der '
            '6-stellige Code unterwegs. Er ist 10 Minuten gültig.';
      });
    });
  }

  Future<void> _resend() async {
    final email = _guardEmail;
    final rest = _remainingSeconds();
    if (rest > 0) {
      setState(() => _error = _l10n.authCodeThrottleWait(rest));
      return;
    }
    await _run(() async {
      await _sendGuarded(
        email,
        () => _isRecovery
            ? widget.authRepository.sendPasswordReset(email)
            : widget.authRepository.resendSignupCode(email),
      );
      if (!mounted) return;
      setState(() => _message =
          'Neuer Code angefordert — er ist 10 Minuten gültig.');
    });
  }

  Future<void> _verify() async {
    if (_locked) return;
    final code = _code.text.trim();
    if (code.length != 6) {
      setState(() => _error = 'Der Code hat 6 Ziffern.');
      return;
    }
    final email = _guardEmail;
    await _run(() async {
      try {
        if (_isRecovery) {
          await widget.authRepository
              .verifyRecoveryCode(email: email, code: code);
          if (!mounted) return;
          setState(() => _step = _Step.password);
        } else {
          await widget.authRepository
              .verifySignupCode(email: email, code: code);
          if (!mounted) return;
          // Session steht — der AuthGate unter dieser Route wechselt auf die
          // Home-Page, die Seite hat ihren Zweck erfuellt.
          Navigator.of(context).pop();
        }
      } catch (error) {
        // Nur ein wirklich ABGELEHNTER Code zaehlt: ein Netz- oder
        // Drosselfehler heisst, der Server hat gar nicht geprueft.
        if (_classifyAuthError(error) == _AuthErrorKind.codeRejected) {
          _countFailedAttempt(email);
          if (_locked) {
            // Dieser Fehlversuch hat die Sperre gerade ausgeloest: ab jetzt
            // uebernimmt der Dauerhinweis in build() (`authCodeTooManyAttempts`)
            // die Meldung. Wuerde hier trotzdem weitergeworfen, setzte `_run`
            // den codespezifischen Fehlertext in `_error` — und der haette laut
            // build() VORRANG vor dem Dauerhinweis, obwohl der Nutzer am
            // gesperrten Feld nichts mehr tun kann. Ein spaeter neu
            // auftretender Fehler (z.B. beim Neuanfordern waehrend der Sperre)
            // ist davon unberuehrt: der setzt `_error` erst NACH diesem Punkt.
            return;
          }
        }
        rethrow;
      }
    });
  }

  Future<void> _savePassword() async {
    if (_password.text.length < 8) {
      setState(() => _error = 'Das Passwort braucht mindestens 8 Zeichen.');
      return;
    }
    await _run(() async {
      await widget.authRepository.updatePassword(_password.text);
      if (!mounted) return;
      Navigator.of(context).pop();
      showAppSnack(
        context,
        'Passwort aktualisiert. Du bist eingeloggt.',
        icon: Icons.lock_reset_rounded,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final gesperrt = _locked && _step == _Step.code;
    // Ein AKTUELLER Fehler (z.B. ein gescheitertes Neuanfordern waehrend der
    // Sperre — offline, GoTrue-Drossel) hat Vorrang vor dem Dauerhinweis der
    // Sperre; ohne `_error` faellt die Meldung auf den Dauerhinweis zurueck.
    // Vorher verschluckte `gesperrt ? ... : _error` JEDEN weiteren Fehler,
    // sobald die Sperre einmal griff — der Link wirkte tot (W3).
    final fehlerText =
        _error ?? (gesperrt ? _l10n.authCodeTooManyAttempts : null);
    return SecureScreenGuard(
      child: Scaffold(
      key: const ValueKey('auth-code-screen'),
      backgroundColor: bg,
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          key: const ValueKey('auth-code-back'),
          onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded, size: 20),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
              24, 8, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                switch (_step) {
                  _Step.email => 'Passwort zurücksetzen',
                  _Step.code => 'Code eingeben',
                  _Step.password => 'Neues Passwort',
                },
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.8,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                switch (_step) {
                  _Step.email =>
                    'Wir schicken dir einen 6-stelligen Code per E-Mail.',
                  _Step.code => _isRecovery
                      ? 'Gib den Code aus der E-Mail an ${_email.text.trim()} ein.'
                      : 'Bestätige deine E-Mail ${_email.text.trim()} mit dem '
                          'Code aus der Willkommens-Mail.',
                  _Step.password =>
                    'Der Code stimmt. Leg jetzt dein neues Passwort fest.',
                },
                style: const TextStyle(
                  color: textMuted,
                  fontSize: 13.5,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 26),
              if (_step == _Step.email) ...[
                _CapsuleField(
                  fieldKey: const ValueKey('code-email-field'),
                  controller: _email,
                  hint: 'du@beispiel.de',
                  icon: Icons.alternate_email_rounded,
                  enabled: !_busy,
                  keyboardType: TextInputType.emailAddress,
                  onSubmitted: _sendCode,
                ),
              ],
              if (_step == _Step.code) ...[
                _CodeField(
                  fieldKey: const ValueKey('code-field'),
                  controller: _code,
                  enabled: !_busy && !gesperrt,
                  onSubmitted: _verify,
                ),
              ],
              if (_step == _Step.password) ...[
                _CapsuleField(
                  fieldKey: const ValueKey('code-password-field'),
                  controller: _password,
                  hint: 'Mind. 8 Zeichen',
                  icon: Icons.lock_outline_rounded,
                  enabled: !_busy,
                  autofillHints: const [AutofillHints.newPassword],
                  obscure: !_passwordVisible,
                  onSubmitted: _savePassword,
                  trailing: GestureDetector(
                    onTap: () =>
                        setState(() => _passwordVisible = !_passwordVisible),
                    child: Icon(
                      _passwordVisible
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                      size: 19,
                      color: textMuted,
                    ),
                  ),
                ),
              ],
              if (fehlerText != null) ...[
                const SizedBox(height: 14),
                _Note(
                    noteKey: const ValueKey('code-error'),
                    text: fehlerText,
                    color: danger),
              ],
              if (_message != null) ...[
                const SizedBox(height: 14),
                _Note(
                    noteKey: const ValueKey('code-message'),
                    text: _message!,
                    color: lime),
              ],
              const SizedBox(height: 22),
              FilledButton(
                key: const ValueKey('code-primary'),
                onPressed: _busy || gesperrt
                    ? null
                    : switch (_step) {
                        _Step.email => _sendCode,
                        _Step.code => _verify,
                        _Step.password => _savePassword,
                      },
                style: FilledButton.styleFrom(
                  backgroundColor: lime,
                  foregroundColor: bg,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(rControl),
                  ),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: bg),
                      )
                    : Text(
                        switch (_step) {
                          _Step.email => 'Code anfordern',
                          _Step.code => 'Code prüfen',
                          _Step.password => 'Passwort speichern',
                        },
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 14),
                      ),
              ),
              if (_step == _Step.code) ...[
                const SizedBox(height: 12),
                Center(
                  child: GestureDetector(
                    key: const ValueKey('code-resend'),
                    // Waehrend des Cooldowns bleibt der Tap absichtlich
                    // moeglich: _resend sagt dann, wie lange es noch dauert —
                    // ein toter Link liesse den Nutzer raten.
                    onTap: _busy ? null : _resend,
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text(
                        _cooldownSeconds > 0
                            ? _l10n.authCodeResendCountdown(_cooldownSeconds)
                            : 'Keinen Code bekommen? Neuen anfordern',
                        style: const TextStyle(
                          color: textMuted,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
    );
  }
}

/// Rahmenlose Soft-Kapsel (Design-Vorgabe: keine Hairlines/Fokusringe,
/// Fokus = Flaechen-Aufhellung).
class _CapsuleField extends StatefulWidget {
  const _CapsuleField({
    required this.fieldKey,
    required this.controller,
    required this.hint,
    required this.icon,
    required this.enabled,
    required this.onSubmitted,
    this.obscure = false,
    this.keyboardType,
    this.autofillHints,
    this.trailing,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool enabled;
  final bool obscure;
  final TextInputType? keyboardType;
  final Iterable<String>? autofillHints;
  final Widget? trailing;
  final VoidCallback onSubmitted;

  @override
  State<_CapsuleField> createState() => _CapsuleFieldState();
}

class _CapsuleFieldState extends State<_CapsuleField> {
  final FocusNode _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focused != _focus.hasFocus) {
        setState(() => _focused = _focus.hasFocus);
      }
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      height: 52,
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          Colors.white.withValues(alpha: _focused ? 0.055 : 0.0),
          surfaceSoft,
        ),
        borderRadius: BorderRadius.circular(rControl),
      ),
      child: Row(
        children: [
          Icon(widget.icon, size: 18, color: _focused ? lime : textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              key: widget.fieldKey,
              controller: widget.controller,
              focusNode: _focus,
              enabled: widget.enabled,
              obscureText: widget.obscure,
              keyboardType: widget.keyboardType,
              autofillHints: widget.autofillHints,
              cursorColor: lime,
              onSubmitted: (_) => widget.onSubmitted(),
              style: const TextStyle(fontSize: 14.5),
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle: const TextStyle(color: textMuted, fontSize: 14),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                filled: false,
                isCollapsed: true,
              ),
            ),
          ),
          if (widget.trailing != null) widget.trailing!,
        ],
      ),
    );
  }
}

/// Grosse Code-Kapsel: 6 Ziffern, weit gesperrt, tabular — die Zahl ist der
/// Held der Seite.
class _CodeField extends StatelessWidget {
  const _CodeField({
    required this.fieldKey,
    required this.controller,
    required this.enabled,
    required this.onSubmitted,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: surfaceSoft,
        borderRadius: BorderRadius.circular(rCard),
      ),
      alignment: Alignment.center,
      child: TextField(
        key: fieldKey,
        controller: controller,
        enabled: enabled,
        autofocus: true,
        keyboardType: TextInputType.number,
        // Ohne den Hinweis bietet der Passwortmanager den gerade
        // eingegangenen Code gar nicht erst an.
        autofillHints: const [AutofillHints.oneTimeCode],
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(6),
        ],
        textAlign: TextAlign.center,
        cursorColor: lime,
        onSubmitted: (_) => onSubmitted(),
        style: const TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w800,
          letterSpacing: 10,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
        decoration: const InputDecoration(
          hintText: '······',
          hintStyle: TextStyle(color: textMuted, letterSpacing: 10),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          filled: false,
          isCollapsed: true,
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.noteKey, required this.text, required this.color});

  final Key noteKey;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: noteKey,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(rControl),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 12.5, height: 1.4),
      ),
    );
  }
}
