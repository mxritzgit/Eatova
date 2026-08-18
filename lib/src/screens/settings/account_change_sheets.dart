import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../auth/auth_repository.dart';
import '../../l10n/l10n.dart';
import '../../services/secure_screen.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/design/design.dart';
import 'account_change_messages.dart';
import 'settings_controls.dart';

// ---------------------------------------------------------------------------
// Die zwei Konto-Aenderungen der Einstellungen (2026-08-10).
//
// WARUM SHEETS UND KEINE ROUTEN
// Der Einstellungs-Screen kennt beide Formen und trennt sie nach Zweck:
// „Profil & Ziele" ist eine eigene SEITE (ein Formular, das man bearbeitet und
// speichert), die Kontoloeschung ist ein SHEET (eine abgeschlossene, kurze
// Bestaetigung ueber der Seite, die man wieder wegwischt). Passwort- und
// Adresswechsel gehoeren zur zweiten Sorte: zwei Felder, ein Code, fertig —
// und danach steht man wieder genau dort, wo man war. Ein Routen-Wechsel
// samt Kopfzeile und Zurueck-Pfeil wuerde eine Tiefe vortaeuschen, die diese
// Vorgaenge nicht haben, und der Weg zurueck waere laenger als der Vorgang.
// Sie benutzen deshalb exakt die Bausteine der Loesch-Bestaetigung
// (`showEatovaSheet` + [SheetScaffold] + [SheetField]).
//
// Beide Sheets haben ZWEI Schritte im selben Sheet statt zwei Sheets
// hintereinander: der zweite Schritt braucht den ersten (ohne angeforderten
// Code gibt es nichts einzutippen), und ein Sheet, das sich schliesst und
// sofort wieder oeffnet, sieht aus wie ein Fehler.
//
// [SecureScreenGuard] liegt um beide: Codes und Mailadressen gehoeren nicht
// ins Vorschaubild des App-Umschalters. Der Guard ist ref-gezaehlt, die
// Verschachtelung unter dem Guard des Einstellungs-Screens ist also gratis —
// und sie macht die Sheets unabhaengig davon, wer sie oeffnet.
// ---------------------------------------------------------------------------

/// Oeffnet den Passwort-Wechsel. Liefert `true`, wenn das Passwort wirklich
/// gesetzt wurde — nur dann zeigt der Aufrufer seine Bestaetigung.
Future<bool> showPasswordChangeSheet(
  BuildContext context, {
  required AuthRepository authRepository,
  String? email,
}) async {
  final erfolg = await showEatovaSheet<bool>(
    context,
    SecureScreenGuard(
      child: _PasswordChangeSheet(
        key: const ValueKey<String>('password-change-sheet'),
        authRepository: authRepository,
        email: email,
      ),
    ),
  );
  return erfolg ?? false;
}

/// Oeffnet den Adresswechsel. [currentEmail] ist Pflicht: der erste der beiden
/// Codes wird gegen die BISHERIGE Adresse verifiziert — ohne sie liesse sich
/// der Vorgang nicht abschliessen.
Future<bool> showEmailChangeSheet(
  BuildContext context, {
  required AuthRepository authRepository,
  required String currentEmail,
}) async {
  final erfolg = await showEatovaSheet<bool>(
    context,
    SecureScreenGuard(
      child: _EmailChangeSheet(
        key: const ValueKey<String>('email-change-sheet'),
        authRepository: authRepository,
        currentEmail: currentEmail,
      ),
    ),
  );
  return erfolg ?? false;
}

// ---------------------------------------------------------------------------
// Flow 1 — Passwort aendern
// ---------------------------------------------------------------------------

enum _PasswortSchritt { codeAnfordern, codeUndPasswort }

class _PasswordChangeSheet extends StatefulWidget {
  const _PasswordChangeSheet({
    super.key,
    required this.authRepository,
    this.email,
  });

  final AuthRepository authRepository;

  /// Nur zur Anzeige („Code an …") — GoTrue schickt den Code von sich aus an
  /// die hinterlegte Adresse, die App nennt sie nicht.
  final String? email;

  @override
  State<_PasswordChangeSheet> createState() => _PasswordChangeSheetState();
}

class _PasswordChangeSheetState extends State<_PasswordChangeSheet> {
  final TextEditingController _code = TextEditingController();
  final TextEditingController _neu = TextEditingController();
  final TextEditingController _wiederholung = TextEditingController();

  _PasswortSchritt _schritt = _PasswortSchritt.codeAnfordern;
  bool _busy = false;
  String? _fehler;
  String? _codeFehler;
  String? _neuFehler;
  String? _wiederholungFehler;

  @override
  void dispose() {
    _code.dispose();
    _neu.dispose();
    _wiederholung.dispose();
    super.dispose();
  }

  Future<void> _codeAnfordern() async {
    // Der Doppel-Tap-Riegel liegt hier UND an `actionEnabled`: die Sperre am
    // Knopf greift erst mit dem naechsten Frame.
    if (_busy) return;
    setState(() {
      _busy = true;
      _fehler = null;
    });
    try {
      await widget.authRepository.startPasswordChange();
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
      _schritt = _PasswortSchritt.codeUndPasswort;
    });
  }

  Future<void> _passwortSetzen() async {
    if (_busy) return;
    final l10n = context.l10n;
    final code = _code.text.trim();
    final neu = _neu.text;
    final wiederholung = _wiederholung.text;

    // Alles, was die App selbst wissen kann, wird hier abgefangen. Ein
    // Absende-Knopf, der absehbar in einen Serverfehler laeuft, verbrennt
    // ausserdem den Code — GoTrue akzeptiert eine Nonce nur einmal.
    final codeFehler = isAccountCode(code) ? null : kAccountCodeInvalid(l10n);
    final neuFehler = neu.length < kAccountMinPasswordLength
        ? kAccountPasswordTooShort(l10n)
        : null;
    final wiederholungFehler = neuFehler == null && wiederholung != neu
        ? kAccountPasswordMismatch(l10n)
        : null;

    if (codeFehler != null || neuFehler != null || wiederholungFehler != null) {
      setState(() {
        _fehler = null;
        _codeFehler = codeFehler;
        _neuFehler = neuFehler;
        _wiederholungFehler = wiederholungFehler;
      });
      return;
    }

    setState(() {
      _busy = true;
      _fehler = null;
      _codeFehler = null;
      _neuFehler = null;
      _wiederholungFehler = null;
    });
    try {
      await widget.authRepository
          .confirmPasswordChange(code: code, newPassword: neu);
    } catch (error) {
      if (!mounted) return;
      // Kein Zuruecksetzen der Felder: wer einen Code vertippt, hat das
      // Passwort trotzdem richtig eingegeben.
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
    final adresse = widget.email;
    final ersterSchritt = _schritt == _PasswortSchritt.codeAnfordern;

    return SheetScaffold(
      title: l10n.settingsChangePasswordTitle,
      subtitle: ersterSchritt
          ? (adresse == null
              ? l10n.settingsPasswordChangeCodeSentDefault
              : l10n.settingsPasswordChangeCodeSentTo(adresse))
          : l10n.settingsPasswordChangeStep2Subtitle,
      actionLabel: _aktionsBeschriftung(l10n, ersterSchritt),
      actionEnabled: !_busy,
      onAction: ersterSchritt ? _codeAnfordern : _passwortSetzen,
      children: <Widget>[
        if (!ersterSchritt) ...<Widget>[
          _CodeFeld(
            fieldKey: const ValueKey<String>('password-change-code'),
            label: l10n.settingsPasswordChangeCodeFieldLabel,
            adresse: adresse,
            controller: _code,
            enabled: !_busy,
            errorText: _codeFehler,
          ),
          SheetField(
            key: const ValueKey<String>('password-change-new'),
            label: l10n.settingsPasswordChangeNewLabel,
            hint: l10n.settingsPasswordChangeNewHint,
            obscure: true,
            controller: _neu,
            enabled: !_busy,
            errorText: _neuFehler,
          ),
          SheetField(
            key: const ValueKey<String>('password-change-repeat'),
            label: l10n.settingsPasswordChangeRepeatLabel,
            hint: l10n.settingsPasswordChangeRepeatHint,
            obscure: true,
            controller: _wiederholung,
            enabled: !_busy,
            errorText: _wiederholungFehler,
          ),
        ],
        if (_fehler != null)
          _FehlerNotiz(
            noteKey: const ValueKey<String>('password-change-error'),
            text: _fehler!,
          ),
      ],
    );
  }

  String _aktionsBeschriftung(AppLocalizations l10n, bool ersterSchritt) {
    if (_busy) {
      return ersterSchritt
          ? l10n.settingsPasswordChangeRequestingCta
          : l10n.settingsPasswordChangeSavingCta;
    }
    // Bewusst NICHT „Passwort ändern": so heisst schon die Zeile, aus der
    // dieses Sheet kommt, und der Sheet-Titel. Drei gleiche Beschriftungen im
    // selben Baum sind fuer Screenreader und Tests gleichermassen mehrdeutig.
    return ersterSchritt
        ? l10n.settingsPasswordChangeRequestCta
        : l10n.settingsPasswordChangeSubmitCta;
  }
}

// ---------------------------------------------------------------------------
// Flow 2 — E-Mail-Adresse aendern
// ---------------------------------------------------------------------------

enum _MailSchritt { adresse, codes }

class _EmailChangeSheet extends StatefulWidget {
  const _EmailChangeSheet({
    super.key,
    required this.authRepository,
    required this.currentEmail,
  });

  final AuthRepository authRepository;
  final String currentEmail;

  @override
  State<_EmailChangeSheet> createState() => _EmailChangeSheetState();
}

class _EmailChangeSheetState extends State<_EmailChangeSheet> {
  final TextEditingController _adresse = TextEditingController();
  final TextEditingController _codeAlt = TextEditingController();
  final TextEditingController _codeNeu = TextEditingController();

  _MailSchritt _schritt = _MailSchritt.adresse;
  String _zieladresse = '';
  bool _busy = false;

  /// Welcher der beiden Codes bereits durchging. GoTrue verbrennt einen
  /// bestaetigten Code — waere das nicht gemerkt, machte ein Tippfehler im
  /// ZWEITEN Code den ganzen Vorgang unrettbar, weil der erste beim naechsten
  /// Anlauf abgelehnt wuerde.
  bool _altBestaetigt = false;
  bool _neuBestaetigt = false;

  String? _adressFehler;
  String? _fehlerAlt;
  String? _fehlerNeu;

  @override
  void dispose() {
    _adresse.dispose();
    _codeAlt.dispose();
    _codeNeu.dispose();
    super.dispose();
  }

  Future<void> _codesAnfordern() async {
    if (_busy) return;
    final l10n = context.l10n;
    final ziel = _adresse.text.trim();
    if (!isPlausibleAccountEmail(ziel)) {
      setState(() => _adressFehler = kAccountEmailInvalid(l10n));
      return;
    }
    if (ziel.toLowerCase() == widget.currentEmail.trim().toLowerCase()) {
      setState(() => _adressFehler = kAccountEmailUnchanged(l10n));
      return;
    }

    setState(() {
      _busy = true;
      _adressFehler = null;
    });
    try {
      await widget.authRepository.startEmailChange(ziel);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _adressFehler = accountChangeErrorMessage(error, context.l10n);
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _zieladresse = ziel;
      _schritt = _MailSchritt.codes;
    });
  }

  Future<void> _adresseBestaetigen() async {
    if (_busy) return;
    final l10n = context.l10n;
    final codeAlt = _codeAlt.text.trim();
    final codeNeu = _codeNeu.text.trim();

    // Ein einzelner Code aendert nichts — er wuerde nur verbraucht. Deshalb
    // geht ohne BEIDE gar kein Aufruf raus.
    final fehlerAlt = _altBestaetigt || isAccountCode(codeAlt)
        ? null
        : kAccountCodeInvalid(l10n);
    final fehlerNeu = _neuBestaetigt || isAccountCode(codeNeu)
        ? null
        : kAccountCodeInvalid(l10n);
    if (fehlerAlt != null || fehlerNeu != null) {
      setState(() {
        _fehlerAlt = fehlerAlt;
        _fehlerNeu = fehlerNeu;
      });
      return;
    }

    setState(() {
      _busy = true;
      _fehlerAlt = null;
      _fehlerNeu = null;
    });

    if (!_altBestaetigt) {
      try {
        await widget.authRepository.confirmEmailChange(
          email: widget.currentEmail,
          code: codeAlt,
        );
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _fehlerAlt = accountChangeErrorMessage(error, context.l10n);
        });
        return;
      }
      if (!mounted) return;
      setState(() => _altBestaetigt = true);
    }

    if (!_neuBestaetigt) {
      try {
        await widget.authRepository.confirmEmailChange(
          email: _zieladresse,
          code: codeNeu,
        );
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _fehlerNeu = accountChangeErrorMessage(error, context.l10n);
        });
        return;
      }
      if (!mounted) return;
      setState(() => _neuBestaetigt = true);
    }

    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final ersterSchritt = _schritt == _MailSchritt.adresse;

    return SheetScaffold(
      title: l10n.settingsChangeEmailTitle,
      subtitle: ersterSchritt
          ? l10n.settingsEmailChangeStep1Subtitle(widget.currentEmail)
          : l10n.settingsEmailChangeStep2Subtitle,
      actionLabel: _aktionsBeschriftung(l10n, ersterSchritt),
      actionEnabled: !_busy,
      onAction: ersterSchritt ? _codesAnfordern : _adresseBestaetigen,
      children: <Widget>[
        if (ersterSchritt)
          SheetField(
            key: const ValueKey<String>('email-change-new-address'),
            label: l10n.settingsEmailChangeNewAddressLabel,
            hint: l10n.settingsEmailChangeNewAddressHint,
            controller: _adresse,
            enabled: !_busy,
            keyboardType: TextInputType.emailAddress,
            errorText: _adressFehler,
          )
        else ...<Widget>[
          _CodeFeld(
            fieldKey: const ValueKey<String>('email-change-code-old'),
            label: l10n.settingsEmailChangeOldCodeLabel,
            adresse: widget.currentEmail,
            controller: _codeAlt,
            // Ein bereits bestaetigter Code ist verbraucht — das Feld bleibt
            // sichtbar (der Vorgang soll nachvollziehbar bleiben), aber taub.
            enabled: !_busy && !_altBestaetigt,
            errorText: _fehlerAlt,
            erledigt: _altBestaetigt,
          ),
          _CodeFeld(
            fieldKey: const ValueKey<String>('email-change-code-new'),
            label: l10n.settingsEmailChangeNewCodeLabel,
            adresse: _zieladresse,
            controller: _codeNeu,
            enabled: !_busy && !_neuBestaetigt,
            errorText: _fehlerNeu,
            erledigt: _neuBestaetigt,
          ),
          SettingsNote(
            key: const ValueKey<String>('email-change-both-hint'),
            l10n.settingsEmailChangeBothCodesHint,
            boxed: true,
          ),
        ],
      ],
    );
  }

  String _aktionsBeschriftung(AppLocalizations l10n, bool ersterSchritt) {
    if (_busy) {
      return ersterSchritt
          ? l10n.settingsEmailChangeRequestingCta
          : l10n.settingsEmailChangeCheckingCta;
    }
    return ersterSchritt
        ? l10n.settingsEmailChangeRequestCta
        : l10n.settingsEmailChangeSubmitCta;
  }
}

// ---------------------------------------------------------------------------
// Bausteine dieses Pakets
// ---------------------------------------------------------------------------

/// Ein 6-Ziffern-Feld mit der zugehoerigen Adresse im KLARTEXT darueber.
///
/// Paket-lokal statt [SheetField], weil dessen Beschriftung durch
/// `toUpperCase()` laeuft: „CODE AN ALT@EATOVA.DE" ist zwar lesbar, aber eine
/// Mailadresse in Versalien sieht aus wie ein anderer String — und im
/// Doppel-Code-Schritt haengt alles daran, dass man die beiden Adressen sicher
/// auseinanderhaelt. Der [fieldKey] sitzt bewusst am inneren [TextField]:
/// Tests lesen `widget<TextField>(...).controller`, um zu belegen, dass ein
/// abgelehnter Code die Eingabe stehen laesst.
class _CodeFeld extends StatelessWidget {
  const _CodeFeld({
    required this.fieldKey,
    required this.label,
    required this.controller,
    this.adresse,
    this.enabled = true,
    this.errorText,
    this.erledigt = false,
  });

  final Key fieldKey;
  final String label;
  final TextEditingController controller;

  /// Die Adresse, an die GENAU dieser Code ging.
  final String? adresse;

  final bool enabled;
  final String? errorText;

  /// Dieser Code ist bereits bestaetigt — Haken statt Hinweis.
  final bool erledigt;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final hatFehler = errorText != null;
    final adresszeile = adresse;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  style: AppType.eyebrow(t.ink2, size: 9.5),
                ),
              ),
              if (erledigt)
                Icon(Icons.check_circle_rounded, size: 15, color: t.accent),
            ],
          ),
          if (adresszeile != null && adresszeile.isNotEmpty) ...<Widget>[
            const SizedBox(height: 3),
            Text(
              adresszeile,
              style: AppType.ui(12.5, weight: FontWeight.w600, color: t.ink),
            ),
          ],
          const SizedBox(height: 7),
          Opacity(
            opacity: enabled ? 1 : 0.55,
            child: Container(
              decoration: BoxDecoration(
                color: t.surf,
                borderRadius: BorderRadius.circular(rControl),
                border: Border.all(color: hatFehler ? t.danger : t.line),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 15),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      key: fieldKey,
                      controller: controller,
                      enabled: enabled,
                      // Ohne das laeuft der Cursor-Fade als Dauer-Animation
                      // und `pumpAndSettle` kaeme nie zur Ruhe.
                      cursorOpacityAnimates: false,
                      cursorColor: t.accent,
                      keyboardType: TextInputType.number,
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(kAccountCodeLength),
                      ],
                      style: AppType.display(
                        18,
                        weight: FontWeight.w700,
                        color: t.ink,
                        letterSpacing: 5,
                      ),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        filled: false,
                        isDense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 15),
                        hintText: '••••••••',
                        hintStyle:
                            AppType.ui(14, color: t.ink2, letterSpacing: 5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (hatFehler) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              errorText!,
              style: AppType.ui(11.5, weight: FontWeight.w500, color: t.danger),
            ),
          ],
        ],
      ),
    );
  }
}

/// Die Sammelmeldung am Fuss eines Sheets — dieselbe Optik wie [SettingsNote],
/// nur immer im Danger-Ton und mit dem passenden Glyph.
class _FehlerNotiz extends StatelessWidget {
  const _FehlerNotiz({required this.noteKey, required this.text});

  final Key noteKey;
  final String text;

  @override
  Widget build(BuildContext context) {
    return SettingsNote(
      key: noteKey,
      text,
      tone: context.t.danger,
      icon: Icons.error_outline_rounded,
      boxed: true,
    );
  }
}
