/// Coach-Tab — als Bibliothek aus mehreren `part`-Dateien zusammengesetzt.
///
/// Rein mechanischer Split der frueheren 2000-Zeilen-Datei: die kohaerenten
/// Widget-Gruppen liegen in den unten referenzierten `part of`-Dateien.
/// Importe + Sichtbarkeit (library-private `_`-Klassen) bleiben unveraendert,
/// kein Import-Site aendert sich (Einstieg bleibt [CoachChatScreen]).
/// Der iOS-MethodChannel `eatova/speech` lebt in coach_speech.dart.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/chat_message.dart';
import '../../models/chat_session.dart';
import '../../services/coach_chat_service.dart';
import '../../services/meal_photo_compressor.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';

part 'coach_speech.dart';
part 'coach_top_bar.dart';
part 'coach_hero.dart';
part 'coach_orb.dart';
part 'coach_message_list.dart';
part 'coach_composer.dart';
part 'coach_sessions.dart';

/// Coach-Chat: Grok-basierter Fitness-/Ernaehrungs-Coach.
///
/// Design-Refactor 2026-08-09: Kopfzeile mit Forest-Kachel, „KI-Coach" und
/// Zustandszeile, daneben Streak/(i)/Unterhaltungen. Leerzustand = animierter
/// [CoachOrb] mit Zeit-Begruessung, C8-Hinweis und den Vorschlags-Zeilen; im
/// Verlauf Blasen (Nutzer rechts auf [AppTokens.forest], Coach links auf
/// [AppTokens.surf] mit 1-px-Rand). Der Composer ist eine Kapsel mit
/// "+"-Attach, Mic und dem Forest/Lime-Senden-Knopf.
class CoachChatScreen extends StatefulWidget {
  const CoachChatScreen({
    super.key,
    required this.service,
    this.userName = 'Moritz',
    this.streak = 0,
    this.userContext,
    this.imagePicker,
    this.speechInput = const CoachSpeechInput(),
  });

  final CoachChatService? service;
  final String userName;

  /// Anzeige-Streak fuer die Pill oben links. Der Aufrufer reicht
  /// `lifetimeStats.effectiveStreakOn(now)` herein — nie `currentStreak`
  /// direkt, sonst zeigt eine gerissene Kette nicht 0.
  final int streak;

  /// Kompakter Snapshot von Profil + Tagesbilanz (Restmakros/kcal/Gewicht/
  /// Streak), den der Coach als Kontext erhält, damit er konkret beraten kann
  /// ("dir fehlen heute 38 g Protein") statt generisch zu antworten.
  final String? userContext;

  final ImagePicker? imagePicker;
  final CoachSpeechInput speechInput;

  @override
  State<CoachChatScreen> createState() => _CoachChatScreenState();
}

class _CoachChatScreenState extends State<CoachChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocus = FocusNode();

  List<ChatMessage> _messages = const <ChatMessage>[];
  List<ChatSession> _sessions = const <ChatSession>[];

  /// `null` heisst „ich weiss es nicht" — nicht „voll" und nicht „leer".
  ///
  /// Frueher stand hier `ChatQuotaSnapshot.unknown`, das mit `remaining: 5`
  /// belegt war. Jeder gescheiterte RPC hat damit ein erschoepftes Kontingent
  /// wieder aufgefuellt und die Sperre aufgehoben (Review D2). Ein Snapshot
  /// liegt jetzt nur vor, wenn der Server tatsaechlich Zahlen genannt hat.
  ChatQuotaSnapshot? _quota;
  String? _activeSessionId;
  bool _loading = true;
  bool _sending = false;
  bool _listening = false;
  String _draft = '';
  String? _error;

  /// Der Verlauf der aktiven Session war beim letzten Versuch nicht ladbar —
  /// dann darf der Hero-Leerzustand ihn nicht als „leer" praesentieren.
  bool _historyUnavailable = false;

  ImagePicker get _picker => widget.imagePicker ?? ImagePicker();

  /// Nur ein *bekanntermassen* leeres Kontingent sperrt.
  ///
  /// Ein unbekannter Stand (Kaltstart ohne Netz) sperrt ausdruecklich nicht:
  /// der Nutzer hat vielleicht noch Fragen frei, und ueber das Limit
  /// entscheidet ohnehin der Server — er antwortet mit 429, wenn nicht.
  /// Die Unterscheidung ist nicht „gesperrt vs. frei", sondern „was weiss ich".
  bool get _kontingentErschoepft {
    final quota = _quota;
    return quota != null && quota.remaining <= 0;
  }

  /// Rest-Zahl fuer die Anzeige. Widgets brauchen zwingend eine Zahl; bei
  /// unbekanntem Stand steht hier bewusst das Standardlimit, damit weder
  /// „Limit fuer heute erreicht" noch „Noch N Fragen heute" behauptet wird.
  /// Sperr-Entscheidungen laufen NIE ueber diesen Wert, sondern ueber
  /// [_kontingentErschoepft].
  int get _restFuerAnzeige =>
      _quota?.remaining ?? ChatQuotaSnapshot.standardTageslimit;

  int get _limitFuerAnzeige =>
      _quota?.dailyLimit ?? ChatQuotaSnapshot.standardTageslimit;

  /// Tippen ist auch WAEHREND einer laufenden Antwort erlaubt (sonst wuerde
  /// das disabled-TextField mitten im Flow die Tastatur schliessen) —
  /// nur Aktionen (Senden/Mic/Attach) warten auf [_canInteract].
  bool get _canType =>
      widget.service != null &&
      !_loading &&
      !_kontingentErschoepft &&
      _activeSessionId != null;
  bool get _canInteract => _canType && !_sending;

  @override
  void initState() {
    super.initState();
    _input.addListener(() {
      if (_draft != _input.text) setState(() => _draft = _input.text);
    });
    _bootstrap();
  }

  /// Seit D6 haengt dieser Screen im `IndexedStack` und bleibt dauerhaft
  /// gemountet — `_bootstrap()` laeuft also nur noch EINMAL pro App-Lauf.
  /// Damit ist jeder einmalige Fehlausgang dauerhaft: der Tageszaehler wurde
  /// nur noch aus `send()`-Antworten fortgeschrieben (und bei erschoepftem
  /// Kontingent gibt es keine `send()` mehr, die ihn korrigieren koennte), ein
  /// Fehlerbanner blieb bis zum Kaltstart stehen, und eine beim ersten Besuch
  /// gescheiterte Session wurde nie wieder nachgeholt.
  ///
  /// `TickerMode` ist der Hebel: W3-01 schaltet den Ticker des unsichtbaren
  /// Tabs stumm, ein Wechsel auf den Coach-Tab flippt ihn also auf `true` und
  /// loest [_beiRueckkehr] aus — der Moment, in dem der Nutzer den Screen
  /// wieder ansieht. Kein Timer, kein Aufruf beim Verlassen, kein Request im
  /// Hintergrund.
  ///
  /// ACHTUNG: das haengt an der Verdrahtung in `eatova_home_page.dart`
  /// (`TickerMode(enabled: i == tab, …)` im Tab-Stack). Faellt das `TickerMode`
  /// dort weg, faellt alles hier still aus.
  bool _sichtbar = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final sichtbar = TickerMode.valuesOf(context).enabled;
    final wurdeSichtbar = sichtbar && !_sichtbar;
    _sichtbar = sichtbar;
    final svc = widget.service;
    // Nur beim Wiedersichtbarwerden und nur, wenn der Bootstrap durch ist —
    // sonst laufen zwei Aufrufe gegeneinander.
    if (!wurdeSichtbar || svc == null || _loading) return;
    // Nach dem Frame: [_beiRueckkehr] darf setState rufen, und
    // didChangeDependencies laeuft mitten in der Build-Phase.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_beiRueckkehr(svc));
    });
  }

  /// Alles, was frueher der Tab-Wechsel nebenbei erledigte, weil der Screen
  /// unmountete und komplett neu hochfuhr. Seit D6 bleibt er gemountet — was
  /// hier nicht steht, passiert bis zum Kaltstart nicht mehr.
  Future<void> _beiRueckkehr(CoachChatService svc) async {
    // Heilungspfad: ging der erste Bootstrap ohne Session aus (offline beim
    // ersten Coach-Besuch), blieb `_activeSessionId` bisher fuer den REST DES
    // APP-LAUFS null — der Composer war dauerhaft tot, weil hier nur die Quota
    // nachgezogen wurde, nie die Session.
    if (_activeSessionId == null) {
      await _bootstrap();
      return;
    }
    await _refreshQuota(svc);
    // Das Fehlerbanner ist Rueckmeldung auf eine Aktion, kein Dauerzustand.
    // Vor D6 raeumte der Tab-Wechsel es mit dem Screen ab; danach stand ein
    // einmal gesetzter Fehler bis zum Kaltstart im Bild.
    if (mounted && _error != null) setState(() => _error = null);
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// Laeuft nie zweimal gleichzeitig: seit der Heilungspfad in
  /// [_beiRueckkehr] den Bootstrap erneut anstossen kann, ist das kein
  /// theoretischer Fall mehr.
  bool _bootstrapLaeuft = false;

  Future<void> _bootstrap() async {
    if (_bootstrapLaeuft) return;
    _bootstrapLaeuft = true;
    try {
      await _bootstrapIntern();
    } finally {
      _bootstrapLaeuft = false;
    }
  }

  Future<void> _bootstrapIntern() async {
    final svc = widget.service;
    if (svc == null) {
      setState(() {
        _loading = false;
        _error = 'Bitte erst einloggen, um den Coach zu nutzen.';
      });
      return;
    }
    // Nur im Wiederholungslauf: Spinner zeigen, altes Banner abraeumen. Beim
    // ersten Lauf aus initState ist `_loading` schon true — dort duerfte gar
    // kein setState fallen.
    if (!_loading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    List<ChatSession> sessions;
    try {
      sessions = await svc.loadSessions();
    } on CoachDataUnavailable {
      // Offline: „keine Liste bekommen" ist nicht „keine Sessions vorhanden".
      // Der naechste Schritt fragt ohnehin nach einer Default-Session.
      sessions = const <ChatSession>[];
    }
    final activeId = sessions.isNotEmpty
        ? sessions.first.id
        : await svc.ensureDefaultSession();
    if (activeId == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Konnte keine Coach-Session laden.';
      });
      return;
    }
    final List<ChatMessage> history;
    try {
      history = await svc.loadHistory(activeId);
    } on CoachDataUnavailable {
      // „Nicht ladbar" ist nicht „leer": ein leeres _messages zeigte den
      // Hero-Leerzustand und praesentierte den Verlauf als geloescht.
      if (!mounted) return;
      setState(() {
        _loading = false;
        _historyUnavailable = true;
        _error = 'Dein Verlauf konnte nicht geladen werden. Prüf deine '
            'Verbindung und versuch es nochmal.';
      });
      return;
    }
    _historyUnavailable = false;
    // Unbekannt bleibt unbekannt: der zuletzt bekannte Stand (beim Kaltstart
    // keiner) ueberlebt, statt durch eine Vermutung ersetzt zu werden.
    ChatQuotaSnapshot? quota = _quota;
    try {
      quota = await svc.loadQuotaToday();
    } on CoachDataUnavailable {
      // absichtlich leer — `quota` behaelt den bekannten Stand.
    }
    var refreshedSessions = sessions;
    if (sessions.isEmpty) {
      try {
        refreshedSessions = await svc.loadSessions();
      } on CoachDataUnavailable {
        refreshedSessions = _sessions;
      }
    }
    if (!mounted) return;
    setState(() {
      _sessions = refreshedSessions;
      _activeSessionId = activeId;
      _messages = history;
      _quota = quota;
      _loading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
  }

  /// Holt den Tageszaehler neu und uebernimmt ihn in die Anzeige.
  ///
  /// Der `catch` ist seit W6-07 erreichbarer Code: [CoachChatService
  /// .loadQuotaToday] wirft, statt einen erfundenen Snapshot zu liefern.
  /// Vorher fing dieser Block etwas ab, das nie geworfen wurde — waehrend der
  /// Schaden (ein erschoepftes Kontingent wird von einer Netzstoerung wieder
  /// aufgefuellt) eine Zeile weiter unten ungehindert passierte.
  ///
  /// Regel: eine Netzstoerung darf das Kontingent weder verbrauchen noch
  /// verschenken. Wir wissen dann schlicht nichts Neues.
  Future<void> _refreshQuota(CoachChatService svc) async {
    final ChatQuotaSnapshot frisch;
    try {
      frisch = await svc.loadQuotaToday();
    } on CoachDataUnavailable {
      return;
    }
    if (mounted) setState(() => _quota = frisch);
  }

  Future<void> _refreshSessions() async {
    final svc = widget.service;
    if (svc == null) return;
    final List<ChatSession> sessions;
    try {
      sessions = await svc.loadSessions();
    } on CoachDataUnavailable {
      // Der letzte bekannte Stand bleibt stehen: eine Netzstoerung darf das
      // Sessions-Sheet nicht leerraeumen und damit behaupten, es gaebe keine
      // Unterhaltungen.
      return;
    }
    if (!mounted) return;
    setState(() => _sessions = sessions);
  }

  Future<void> _switchToSession(String sessionId) async {
    final svc = widget.service;
    if (svc == null) return;
    if (_activeSessionId == sessionId) return;
    setState(() {
      _loading = true;
      _activeSessionId = sessionId;
      _messages = const <ChatMessage>[];
    });
    final List<ChatMessage> history;
    try {
      history = await svc.loadHistory(sessionId);
    } on CoachDataUnavailable {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _historyUnavailable = true;
        _error = 'Dein Verlauf konnte nicht geladen werden. Prüf deine '
            'Verbindung und versuch es nochmal.';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _messages = history;
      _historyUnavailable = false;
      _loading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
  }

  Future<void> _startNewSession() async {
    final svc = widget.service;
    if (svc == null) return;
    HapticFeedback.selectionClick();
    final id = await svc.createSession();
    if (id == null) return;
    await _refreshSessions();
    if (!mounted) return;
    setState(() {
      _activeSessionId = id;
      _messages = const <ChatMessage>[];
      _error = null;
    });
  }

  Future<void> _deleteSession(String sessionId) async {
    final svc = widget.service;
    if (svc == null) return;
    try {
      await svc.deleteSession(sessionId);
    } on CoachDataUnavailable {
      // Sentinel-Rest S8: nicht geloescht ist nicht geloescht — die Session
      // bleibt in der Liste, und der Nutzer erfaehrt es (Snackbar liegt ueber
      // dem noch offenen Sessions-Sheet).
      if (!mounted) return;
      showAppSnack(
        context,
        'Die Unterhaltung konnte nicht gelöscht werden. Prüf deine '
        'Verbindung und versuch es nochmal.',
        icon: Icons.error_outline_rounded,
        duration: kSnackError,
      );
      return;
    }
    final wasActive = _activeSessionId == sessionId;
    await _refreshSessions();
    if (!mounted) return;
    if (wasActive) {
      if (_sessions.isNotEmpty) {
        await _switchToSession(_sessions.first.id);
      } else {
        // Letzte Session gelöscht: Default neu anlegen UND nachladen, damit
        // die Liste (und das Sheet) die neue Session zeigt statt leer zu sein.
        final fallback = await svc.ensureDefaultSession();
        if (fallback != null) {
          await _refreshSessions();
          await _switchToSession(fallback);
        }
      }
    }
  }

  void _scrollToEnd() {
    if (!_scroll.hasClients) return;
    final ziel = _scroll.position.maxScrollExtent + 240;
    final dauer = motionDuration(context, const Duration(milliseconds: 260));
    // Kein `animateTo(..., Duration.zero)`: DrivenScrollActivity haelt darauf
    // ein `assert(duration > Duration.zero)`. Unter reduzierter Bewegung
    // springt der Verlauf ans Ende, statt dorthin zu gleiten.
    if (dauer == Duration.zero) {
      _scroll.jumpTo(ziel.clamp(0.0, _scroll.position.maxScrollExtent));
      return;
    }
    _scroll.animateTo(ziel, duration: dauer, curve: Curves.easeOutCubic);
  }

  Future<void> _send({
    String? textOverride,
    Uint8List? imageBytes,
    String? imageMimeType,
  }) async {
    final svc = widget.service;
    final sessionId = _activeSessionId;
    final typedText = textOverride ?? _input.text;
    final text = typedText.trim();
    final hasImage = imageBytes != null && imageBytes.isNotEmpty;
    if (svc == null || sessionId == null || _sending || (text.isEmpty && !hasImage)) return;
    // Nur ein bekanntermassen leeres Kontingent blockt hier. Ist der Stand
    // unbekannt, laeuft der Versuch bewusst zum Server — der weiss es genau
    // und antwortet notfalls mit 429 (-> CoachQuotaExceeded weiter unten).
    if (_kontingentErschoepft) {
      setState(() => _error =
          'Tageslimit erreicht ($_limitFuerAnzeige Coach-Fragen pro Tag). Morgen geht\'s weiter.');
      return;
    }

    HapticFeedback.selectionClick();
    final displayText = text.isEmpty
        ? 'Analysiere dieses Bild im Fitness-Kontext.'
        : text;
    final userMsg = ChatMessage(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.user,
      content: displayText,
      createdAt: DateTime.now(),
      imageBytes: imageBytes,
      mediaLabel: hasImage ? 'Bild' : null,
    );

    setState(() {
      _messages = [..._messages, userMsg];
      _input.clear();
      _draft = '';
      _sending = true;
      _error = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());

    try {
      final res = await svc.send(
        displayText,
        sessionId: sessionId,
        imageBase64: hasImage ? base64Encode(imageBytes) : null,
        imageMimeType: hasImage ? (imageMimeType ?? 'image/jpeg') : null,
        userContext: widget.userContext,
      );
      if (!mounted) return;
      setState(() {
        _messages = [
          ..._messages,
          ChatMessage(
            id: 'local-r-${DateTime.now().microsecondsSinceEpoch}',
            role: ChatRole.assistant,
            content: res.reply,
            createdAt: DateTime.now(),
            refusal: res.refusal,
          ),
        ];
        final rest = res.remaining;
        if (rest != null) {
          // Der Server hat gerade Zahlen genannt — ab hier ist der Stand
          // bekannt, auch wenn er es vorher nicht war. Das Limit kommt seit
          // E10 vom Server mit; nur aeltere Function-Deployments fallen auf
          // den bisherigen Anzeige-Stand zurueck.
          final limit = res.dailyLimit ?? _limitFuerAnzeige;
          final frei = rest.clamp(0, limit);
          _quota = ChatQuotaSnapshot(
            used: limit - frei,
            remaining: frei,
            dailyLimit: limit,
          );
        }
        _sending = false;
      });
      HapticFeedback.lightImpact();
      // Sessions im Hintergrund neu laden, damit Auto-Titel / last_message_at
      // im Sheet aktuell sind, ohne den Send-Flow zu blockieren.
      unawaited(_refreshSessions());
    } on CoachQuotaExceeded catch (e) {
      if (!mounted) return;
      setState(() {
        // Der Server hat das Limit ausdruecklich genannt — belastbarer geht es
        // nicht, also ersetzt das jeden vorherigen Stand.
        _quota = ChatQuotaSnapshot(
          used: e.dailyLimit,
          remaining: 0,
          dailyLimit: e.dailyLimit,
        );
        _error = e.message;
        _sending = false;
      });
    } on CoachChatException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _sending = false;
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
  }

  /// Base64 blaeht um +33% auf; die Edge Function kappt bei 6.000.000 Zeichen
  /// (handler.ts:47) und antwortet mit 413. Wir stoppen vorher, damit der
  /// Nutzer nicht erst Megabyte hochlaedt, um dann eine Absage zu lesen.
  static const int _maxImageBytes = 4400000;

  /// Einziger Ausgang fuer Bild-Bytes aus dem Coach (Review C4).
  ///
  /// [compressMealPhoto] backt die Orientierung ein, verkleinert auf 1600 px
  /// und leert danach den kompletten EXIF-Container. Ohne diesen Schritt gehen
  /// Breitengrad, Laengengrad, Hoehe, Aufnahmezeit, Geraetemodell und
  /// Seriennummer an OpenRouter in den USA: `image_picker` skaliert zwar,
  /// kopiert die Tags ueber ImageResizer.copyExif() aber wieder zurueck.
  ///
  /// `compute()`: Dekodieren + Re-Encoden blockiert sonst den UI-Isolate.
  /// Scheitert der Isolate-Start, wird im UI-Isolate komprimiert — lieber ein
  /// kurzer Ruckler als ein Upload mit Koordinaten.
  Future<Uint8List> _scrubImage(Uint8List raw) async {
    try {
      return await compute(compressMealPhoto, raw);
    } catch (_) {
      return compressMealPhoto(raw);
    }
  }

  /// MIME-Typ aus den TATSAECHLICHEN Bytes statt aus dem Dateinamen: nach dem
  /// Scrub ist das Bild immer JPEG, auch wenn die Quelle PNG oder WebP hiess.
  /// Der Datei-Typ-Zweig ist seit dem fail-closed-Scrub (S2: nicht
  /// dekodierbar => Wurf statt Durchreichen) nur noch Defensiv-Netz.
  String _mimeForBytes(Uint8List bytes, XFile file) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    return _mimeTypeFor(file);
  }

  Future<void> _pickAndSendImage(ImageSource source) async {
    if (!_canInteract) return;
    HapticFeedback.selectionClick();
    try {
      final image = await _picker.pickImage(
        source: source,
        // imageQuality/maxWidth duerfen NICHT entfallen: ohne sie reicht iOS
        // die HEIC-Originaldatei durch, die package:image nicht dekodieren
        // kann — [_scrubImage] gaebe sie dann ungescrubbt zurueck.
        imageQuality: 80,
        maxWidth: 1600,
      );
      if (image == null) return;
      final raw = await image.readAsBytes();
      final bytes = await _scrubImage(raw);
      if (!mounted) return;
      if (bytes.lengthInBytes > _maxImageBytes) {
        setState(() => _error =
            'Das Bild ist zu groß für den Coach. Bitte schick ein kleineres.');
        return;
      }
      await _send(
        textOverride: _input.text.trim().isEmpty
            ? 'Analysiere dieses Bild im Fitness-Kontext.'
            : _input.text.trim(),
        imageBytes: bytes,
        imageMimeType: _mimeForBytes(bytes, image),
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _error = _permissionMessageFor(source, e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Das Bild konnte nicht geladen werden.');
    }
  }

  String _mimeTypeFor(XFile file) {
    final mime = file.mimeType?.toLowerCase();
    if (mime == 'image/png' || mime == 'image/webp' || mime == 'image/jpeg') {
      return mime!;
    }
    final path = file.path.toLowerCase();
    if (path.endsWith('.png')) return 'image/png';
    if (path.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  String _permissionMessageFor(ImageSource source, PlatformException e) {
    final permissionText = source == ImageSource.camera
        ? 'Kamerazugriff'
        : 'Fotozugriff';
    final lower = '${e.code} ${e.message}'.toLowerCase();
    if (lower.contains('denied') || lower.contains('permission')) {
      return '$permissionText wurde nicht erlaubt. Du kannst die Berechtigung in den iOS-Einstellungen wieder aktivieren.';
    }
    return 'Das Bild konnte nicht geöffnet werden.';
  }

  Future<void> _toggleSpeechInput() async {
    if (!_canInteract) return;
    HapticFeedback.selectionClick();
    if (_listening) {
      await widget.speechInput.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }

    setState(() {
      _listening = true;
      _error = null;
    });
    try {
      final spokenText = await widget.speechInput.listen(localeId: 'de_DE');
      if (!mounted) return;
      setState(() => _listening = false);
      final text = spokenText?.trim() ?? '';
      if (text.isEmpty) {
        setState(() => _error = 'Ich habe nichts verstanden. Versuch es nochmal.');
        return;
      }
      _input.text = text;
      await _send(textOverride: text);
    } on CoachSpeechException catch (e) {
      if (!mounted) return;
      setState(() {
        _listening = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _listening = false;
        _error = 'Spracherkennung ist auf diesem Gerät gerade nicht verfügbar.';
      });
    }
  }

  /// Ein Vorschlag-Chip legt den Text nur ins Feld (statt direkt zu senden) —
  /// die Quota ist knapp, der User behaelt die Kontrolle vor dem Abschicken.
  void _applySuggestion(String text) {
    if (!_canType) return;
    HapticFeedback.selectionClick();
    _input.text = text;
    _input.selection = TextSelection.collapsed(offset: text.length);
    _inputFocus.requestFocus();
  }

  void _openAttachSheet() {
    if (!_canInteract) return;
    HapticFeedback.selectionClick();
    // showEatovaSheet nimmt ein fertiges Widget statt eines Builders. Der
    // `Builder` holt den Context UNTERHALB der Sheet-Route zurueck: mit dem
    // Screen-Context wuerde `pop()` blind die oberste Route treffen — solange
    // das Sheet oben liegt zufaellig richtig, nach einem Wisch-Schliessen aber
    // die Home-Route.
    showEatovaSheet<void>(
      context,
      Builder(
        builder: (sheetContext) => SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _AttachTile(
                  key: const ValueKey('coach-camera'),
                  icon: Icons.photo_camera_outlined,
                  label: 'Foto aufnehmen',
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _pickAndSendImage(ImageSource.camera);
                  },
                ),
                const SizedBox(height: 6),
                _AttachTile(
                  key: const ValueKey('coach-gallery'),
                  icon: Icons.photo_outlined,
                  label: 'Aus der Galerie',
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _pickAndSendImage(ImageSource.gallery);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openSessionsSheet() {
    HapticFeedback.selectionClick();
    showEatovaSheet<void>(
      context,
      // StatefulBuilder, damit das Sheet nach einem Delete sofort neu baut:
      // das Sheet hängt nicht am setState der Page, deshalb sah man die
      // gelöschte Session sonst erst nach Schließen + Neuöffnen verschwinden.
      StatefulBuilder(
        builder: (sheetContext, setSheetState) => _SessionsSheet(
          sessions: _sessions,
          activeSessionId: _activeSessionId,
          onNew: () async {
            Navigator.of(sheetContext).pop();
            await _startNewSession();
          },
          onSelect: (id) async {
            Navigator.of(sheetContext).pop();
            await _switchToSession(id);
          },
          onDelete: (id) async {
            await _deleteSession(id);
            // _sessions wurde in _deleteSession aktualisiert — Sheet mit der
            // frischen Liste neu zeichnen.
            if (mounted) setSheetState(() {});
          },
        ),
      ),
    );
  }

  /// (i)-Sheet: KI-Offenlegung (C8) + Tageskontingent. Erreichbar ueber das
  /// (i) im Kopf, den Hinweis im Leerzustand und den Quota-Hinweis.
  void _openCoachInfoSheet() {
    HapticFeedback.selectionClick();
    final limit = _limitFuerAnzeige;
    final remaining = _restFuerAnzeige.clamp(0, limit);
    showEatovaSheet<void>(
      context,
      _CoachInfoSheet(remaining: remaining, dailyLimit: limit),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Kein Hero, wenn der Verlauf nur NICHT LADBAR war: der Leerzustand
    // behauptet „noch keine Unterhaltung", waehrend der Verlauf existiert
    // (Sentinel-Rest S3). Stattdessen leere Konversation + Fehler-Banner.
    final isHero = !_loading && _messages.isEmpty && !_historyUnavailable;
    return Column(
      key: const ValueKey('screen-coach'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Der Kopf bringt seinen Abstand selbst mit (Trennlinie + 14 px).
        _CoachTopBar(
          streak: widget.streak,
          onInfoTap: _openCoachInfoSheet,
          onSessionsTap: _openSessionsSheet,
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: motionDuration(context, const Duration(milliseconds: 220)),
            child: _loading
                ? const Center(
                    key: ValueKey('coach-loading'),
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      // Farbe kommt aus progressIndicatorTheme (t.accent).
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : isHero
                    ? _CoachHero(
                        name: widget.userName,
                        onDisclosureTap: _openCoachInfoSheet,
                        onSuggestion: _applySuggestion,
                      )
                    : _Conversation(
                        controller: _scroll,
                        focus: _inputFocus,
                        messages: _messages,
                        sending: _sending,
                      ),
          ),
        ),
        // Die Vorschlaege haengen weiter an `isHero`, sitzen jetzt aber im
        // Hero selbst (dort koennen sie scrollen) — Begruendung in
        // coach_hero.dart.
        if (_error != null) _ErrorBanner(text: _error!),
        const SizedBox(height: 8),
        _Composer(
          controller: _input,
          focus: _inputFocus,
          enabled: _canType,
          canSend: _canInteract,
          // Anzeige-Wert, keine Zustandsangabe: bei unbekanntem Stand steht
          // hier das Standardlimit, damit der Composer weder „Limit fuer
          // heute erreicht" noch „Noch N Fragen heute" behauptet.
          remaining: _restFuerAnzeige,
          draft: _draft,
          listening: _listening,
          onSubmit: () => _send(),
          onMic: _toggleSpeechInput,
          onAttach: _openAttachSheet,
          onQuotaTap: _openCoachInfoSheet,
        ),
      ],
    );
  }
}
