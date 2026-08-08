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
import '../../theme/app_colors.dart';
import '../../widgets/common/motion.dart';

part 'coach_speech.dart';
part 'coach_top_bar.dart';
part 'coach_hero.dart';
part 'coach_orb.dart';
part 'coach_message_list.dart';
part 'coach_composer.dart';
part 'coach_sessions.dart';

/// Coach-Chat: Grok-basierter Fitness-/Ernaehrungs-Coach.
///
/// Design nach dem "AI Coach v2"-Entwurf: radialer coachAccent-Schein hinter
/// dem oberen Bereich, Streak-Pill oben links + Sessions/(i) oben rechts.
/// Empty State = animierter [CoachOrb] mit Zeit-Begruessung + volle
/// Vorschlags-Zeilen; im Verlauf User-Bubbles in coachAccent, Coach als
/// Plain-Text mit Tipp-Punkten. Der Composer: rahmenlose Soft-Pill
/// (cardShadow), "+"-Attach links (Kamera/Galerie via Sheet), Mic + runder
/// Send-Kreis rechts (faerbt sich mit Draft in coachAccent).
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

  /// Aktueller Streak (lifetimeStats.currentStreak) fuer die Pill oben links.
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
  ChatQuotaSnapshot _quota = ChatQuotaSnapshot.unknown;
  String? _activeSessionId;
  bool _loading = true;
  bool _sending = false;
  bool _listening = false;
  String _draft = '';
  String? _error;

  ImagePicker get _picker => widget.imagePicker ?? ImagePicker();

  /// Tippen ist auch WAEHREND einer laufenden Antwort erlaubt (sonst wuerde
  /// das disabled-TextField mitten im Flow die Tastatur schliessen) —
  /// nur Aktionen (Senden/Mic/Attach) warten auf [_canInteract].
  bool get _canType =>
      widget.service != null &&
      !_loading &&
      _quota.remaining > 0 &&
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
  /// Der Tageszaehler wurde danach ausschliesslich aus `send()`-Antworten
  /// fortgeschrieben, und bei erschoepftem Kontingent ist der Composer
  /// deaktiviert: es gibt dann gar keine `send()` mehr, die ihn korrigieren
  /// koennte. Wer die App ueber die UTC-Mitternacht offen liess, blieb bis
  /// zum Kaltstart ausgesperrt.
  ///
  /// `TickerMode` ist der Hebel: W3-01 schaltet den Ticker des unsichtbaren
  /// Tabs stumm, ein Wechsel auf den Coach-Tab flippt ihn also auf `true` und
  /// loest genau hier aus — der Moment, in dem der Nutzer die Zahl sieht.
  /// Kein Timer, kein Aufruf beim Verlassen, kein Request im Hintergrund.
  bool _sichtbar = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final sichtbar = TickerMode.valuesOf(context).enabled;
    final wurdeSichtbar = sichtbar && !_sichtbar;
    _sichtbar = sichtbar;
    final svc = widget.service;
    // Nur beim Wiedersichtbarwerden und nur, wenn der Bootstrap durch ist —
    // sonst laufen zwei Quota-Aufrufe gegeneinander.
    if (wurdeSichtbar && svc != null && !_loading) {
      unawaited(_refreshQuota(svc));
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final svc = widget.service;
    if (svc == null) {
      setState(() {
        _loading = false;
        _error = 'Bitte erst einloggen, um den Coach zu nutzen.';
      });
      return;
    }
    final sessions = await svc.loadSessions();
    String? activeId = sessions.isNotEmpty ? sessions.first.id : null;
    if (activeId == null) {
      activeId = await svc.ensureDefaultSession();
    }
    if (activeId == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Konnte keine Coach-Session laden.';
      });
      return;
    }
    final history = await svc.loadHistory(activeId);
    final quota = await svc.loadQuotaToday();
    final refreshedSessions =
        sessions.isEmpty ? await svc.loadSessions() : sessions;
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
  /// Gibt den frischen Stand auch dann zurueck, wenn das Widget zwischenzeitlich
  /// entsorgt wurde — der Aufrufer entscheidet selbst, ob er noch rendert.
  /// Scheitert der Aufruf (offline), bleibt der bekannte Stand stehen: eine
  /// Netzstoerung darf das Kontingent weder verbrauchen noch verschenken.
  Future<ChatQuotaSnapshot> _refreshQuota(CoachChatService svc) async {
    ChatQuotaSnapshot frisch;
    try {
      frisch = await svc.loadQuotaToday();
    } catch (_) {
      return _quota;
    }
    if (mounted) setState(() => _quota = frisch);
    return frisch;
  }

  Future<void> _refreshSessions() async {
    final svc = widget.service;
    if (svc == null) return;
    final sessions = await svc.loadSessions();
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
    final history = await svc.loadHistory(sessionId);
    if (!mounted) return;
    setState(() {
      _messages = history;
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
    await svc.deleteSession(sessionId);
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
    _scroll.animateTo(
      _scroll.position.maxScrollExtent + 240,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
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
    if (_quota.remaining <= 0) {
      setState(() => _error =
          'Tageslimit erreicht (${_quota.dailyLimit} Coach-Fragen pro Tag). Morgen geht\'s weiter.');
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
        if (res.remaining != null) {
          _quota = _quota.copyWith(
            remaining: res.remaining,
            used: _quota.dailyLimit - res.remaining!.clamp(0, _quota.dailyLimit),
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
        _quota = _quota.copyWith(
          remaining: 0,
          used: e.dailyLimit,
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
  /// Nur wenn [compressMealPhoto] nicht dekodieren konnte und die Bytes
  /// unveraendert durchreicht, zaehlt wieder der Typ der Datei.
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
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(rSheet)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: hairline,
                    borderRadius: BorderRadius.circular(rPill),
                  ),
                ),
              ),
              _AttachTile(
                key: const ValueKey('coach-camera'),
                icon: Icons.photo_camera_outlined,
                label: 'Foto aufnehmen',
                onTap: () {
                  Navigator.of(ctx).pop();
                  _pickAndSendImage(ImageSource.camera);
                },
              ),
              const SizedBox(height: 6),
              _AttachTile(
                key: const ValueKey('coach-gallery'),
                icon: Icons.photo_outlined,
                label: 'Aus der Galerie',
                onTap: () {
                  Navigator.of(ctx).pop();
                  _pickAndSendImage(ImageSource.gallery);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openSessionsSheet() {
    HapticFeedback.selectionClick();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(rSheet)),
      ),
      // StatefulBuilder, damit das Sheet nach einem Delete sofort neu baut:
      // showModalBottomSheet hängt nicht am setState der Page, deshalb sah man
      // die gelöschte Session sonst erst nach Schließen + Neuöffnen verschwinden.
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) => _SessionsSheet(
          sessions: _sessions,
          activeSessionId: _activeSessionId,
          onNew: () async {
            Navigator.of(context).pop();
            await _startNewSession();
          },
          onSelect: (id) async {
            Navigator.of(context).pop();
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
  /// (i) in der Top-Bar, den Hinweis im Leerzustand und den Quota-Pill.
  void _openCoachInfoSheet() {
    HapticFeedback.selectionClick();
    final remaining = _quota.remaining.clamp(0, _quota.dailyLimit);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(rSheet)),
      ),
      builder: (_) => _CoachInfoSheet(
        remaining: remaining,
        dailyLimit: _quota.dailyLimit,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isHero = !_loading && _messages.isEmpty;
    return DecoratedBox(
      // Radialer Akzent-Schein hinter dem oberen Bereich (AI Coach v2).
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -0.45),
          radius: 1.1,
          colors: [coachAccent.withValues(alpha: 0.09), Colors.transparent],
        ),
      ),
      child: Column(
        key: const ValueKey('screen-coach'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CoachTopBar(
            streak: widget.streak,
            onInfoTap: _openCoachInfoSheet,
            onSessionsTap: _openSessionsSheet,
          ),
          const SizedBox(height: 4),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: _loading
                  ? const Center(
                      key: ValueKey('coach-loading'),
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: coachAccent),
                      ),
                    )
                  : isHero
                      ? _CoachHero(
                          name: widget.userName,
                          onDisclosureTap: _openCoachInfoSheet,
                        )
                      : _Conversation(
                          controller: _scroll,
                          focus: _inputFocus,
                          messages: _messages,
                          sending: _sending,
                        ),
            ),
          ),
          if (isHero) _SuggestionList(onSuggestion: _applySuggestion),
          if (_error != null) _ErrorBanner(text: _error!),
          const SizedBox(height: 8),
          _Composer(
            controller: _input,
            focus: _inputFocus,
            enabled: _canType,
            canSend: _canInteract,
            remaining: _quota.remaining,
            draft: _draft,
            listening: _listening,
            onSubmit: () => _send(),
            onMic: _toggleSpeechInput,
            onAttach: _openAttachSheet,
            onQuotaTap: _openCoachInfoSheet,
          ),
        ],
      ),
    );
  }
}
