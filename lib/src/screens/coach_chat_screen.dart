import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../services/coach_chat_service.dart';
import '../theme/app_colors.dart';
import '../widgets/common/motion.dart';

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

  Future<void> _pickAndSendImage(ImageSource source) async {
    if (!_canInteract) return;
    HapticFeedback.selectionClick();
    try {
      final image = await _picker.pickImage(
        source: source,
        imageQuality: 80,
        maxWidth: 1600,
      );
      if (image == null) return;
      final bytes = await image.readAsBytes();
      if (!mounted) return;
      await _send(
        textOverride: _input.text.trim().isEmpty
            ? 'Analysiere dieses Bild im Fitness-Kontext.'
            : _input.text.trim(),
        imageBytes: bytes,
        imageMimeType: _mimeTypeFor(image),
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

  void _openQuotaSheet() {
    HapticFeedback.selectionClick();
    final remaining = _quota.remaining.clamp(0, _quota.dailyLimit);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(rSheet)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: hairline,
                  borderRadius: BorderRadius.circular(rPill),
                ),
              ),
            ),
            const Text(
              'Coach-Limit',
              style: TextStyle(
                color: textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '$remaining von ${_quota.dailyLimit} Fragen heute frei. Reset um Mitternacht (UTC).',
              style: const TextStyle(
                color: textMuted,
                fontSize: 13,
                height: 1.45,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 14),
            _QuotaBar(remaining: remaining, total: _quota.dailyLimit),
          ],
        ),
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
            onInfoTap: _openQuotaSheet,
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
                      ? _CoachHero(name: widget.userName)
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
            onQuotaTap: _openQuotaSheet,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
class CoachSpeechInput {
  const CoachSpeechInput();

  static const MethodChannel _channel = MethodChannel('fitpilot/speech');

  Future<String?> listen({String localeId = 'de_DE'}) async {
    try {
      return await _channel.invokeMethod<String>('listen', <String, dynamic>{
        'localeId': localeId,
      });
    } on PlatformException catch (e) {
      final code = e.code.toLowerCase();
      if (code.contains('permission') || code.contains('denied')) {
        throw const CoachSpeechException(
          'Mikrofon oder Spracherkennung wurde nicht erlaubt. Du kannst die Berechtigung in den iOS-Einstellungen wieder aktivieren.',
        );
      }
      if (code.contains('unavailable')) {
        throw const CoachSpeechException(
          'Spracherkennung ist auf diesem Gerät gerade nicht verfügbar.',
        );
      }
      throw CoachSpeechException(e.message ?? 'Spracherkennung fehlgeschlagen.');
    } on MissingPluginException {
      throw const CoachSpeechException(
        'Spracherkennung ist auf diesem Gerät gerade nicht verfügbar.',
      );
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // Stop ist best-effort; die laufende listen()-Future liefert sonst den
      // letzten erkannten Text oder laeuft mit ihrem eigenen Fehler aus.
    }
  }
}

class CoachSpeechException implements Exception {
  const CoachSpeechException(this.message);
  final String message;
}

// ---------------------------------------------------------------------------
// Top-Bar (AI Coach v2): Streak-Pill oben LINKS, Wortmarke mittig, (i) +
// Sessions rechts. Die Pill zeigt den echten Streak aus lifetimeStats.
// ---------------------------------------------------------------------------
class _CoachTopBar extends StatelessWidget {
  const _CoachTopBar({
    required this.streak,
    required this.onInfoTap,
    required this.onSessionsTap,
  });

  final int streak;
  final VoidCallback onInfoTap;
  final VoidCallback onSessionsTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Stack(
        children: [
          const Center(
            child: Text(
              'FitPilot',
              style: TextStyle(
                color: textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Center(child: _StreakPill(streak: streak)),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _TopChip(
                    key: const ValueKey('coach-info'),
                    onTap: onInfoTap,
                    child: const Icon(
                      Icons.info_outline_rounded,
                      size: 18,
                      color: textPrimary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  _TopChip(
                    key: const ValueKey('coach-sessions-open'),
                    onTap: onSessionsTap,
                    child: const Icon(
                      Icons.forum_outlined,
                      size: 18,
                      color: textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Streak-Pill (oben links): Akzent-Punkt + Tages-Zahl. Rahmenlos wie die
/// uebrigen Soft-Flaechen der App.
class _StreakPill extends StatelessWidget {
  const _StreakPill({required this.streak});

  final int streak;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('coach-streak'),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(rPill),
        color: surfaceSoft.withValues(alpha: 0.7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
              color: coachAccent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$streak',
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: textPrimary,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 4),
          Text(
            streak == 1 ? 'Tag' : 'Tage',
            style: const TextStyle(fontSize: 11.5, color: textMuted),
          ),
        ],
      ),
    );
  }
}

class _TopChip extends StatelessWidget {
  const _TopChip({super.key, required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: surfaceSoft,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(width: 36, height: 36, child: Center(child: child)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hero (AI Coach v2): animierter Orb + Zeit-Begruessung mit echtem Vornamen.
// ---------------------------------------------------------------------------
class _CoachHero extends StatelessWidget {
  const _CoachHero({required this.name});
  final String name;

  String get _timeGreeting {
    final h = DateTime.now().hour;
    if (h < 5) return 'Gute Nacht';
    if (h < 11) return 'Guten Morgen';
    if (h < 17) return 'Hallo';
    return 'Guten Abend';
  }

  String get _firstName {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Champion';
    return trimmed.split(RegExp(r'\s+')).first;
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const ValueKey('coach-empty'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CoachOrb(size: 92),
          const SizedBox(height: 22),
          Text(
            '$_timeGreeting, $_firstName',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 25,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
              color: textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Wie kann ich dir helfen?',
            style: TextStyle(fontSize: 15, color: textMuted),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Vorschlags-Zeilen (nur im Hero-State, ueber dem Composer): volle Breite mit
// Pfeil. Legen den Text ins Feld statt direkt zu senden — die Quota ist knapp,
// der User behaelt die Kontrolle vor dem Abschicken.
// ---------------------------------------------------------------------------
class _SuggestionList extends StatelessWidget {
  const _SuggestionList({required this.onSuggestion});

  final ValueChanged<String> onSuggestion;

  static const List<String> _suggestions = [
    'Was soll ich heute noch essen?',
    'Wie komme ich auf meine restlichen Proteine?',
    'Wann sollte ich heute schlafen gehen?',
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Column(
        children: [
          for (var i = 0; i < _suggestions.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: surfaceSoft.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(rCard),
                child: InkWell(
                  key: ValueKey('coach-suggestion-$i'),
                  onTap: () => onSuggestion(_suggestions[i]),
                  borderRadius: BorderRadius.circular(rCard),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 15, vertical: 13),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _suggestions[i],
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: textPrimary,
                              letterSpacing: -0.1,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.arrow_forward_rounded,
                          size: 14,
                          color: textPrimary.withValues(alpha: 0.4),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Animierter Coach-Orb (rotierender Sweep + atmender Kern). Unter "Bewegung
// reduzieren" statisch (kein Spin/Breathe), der Look bleibt erhalten.
// ---------------------------------------------------------------------------
class CoachOrb extends StatefulWidget {
  const CoachOrb({super.key, this.size = 92});
  final double size;

  @override
  State<CoachOrb> createState() => _CoachOrbState();
}

class _CoachOrbState extends State<CoachOrb> with TickerProviderStateMixin {
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(seconds: 7));
  late final AnimationController _breathe = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 3600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduce) {
      _spin.stop();
      _breathe.stop();
    } else {
      if (!_spin.isAnimating) _spin.repeat();
      if (!_breathe.isAnimating) _breathe.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final warm = Color.lerp(coachAccent, coachAccentWarm, 0.6)!;
    return SizedBox(
      width: s,
      height: s,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Glow
          Positioned(
            left: -18,
            top: -18,
            right: -18,
            bottom: -18,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: coachAccent.withValues(alpha: 0.3),
                    blurRadius: 40,
                    spreadRadius: 4,
                  ),
                ],
              ),
            ),
          ),
          // Rotierender Ring
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _spin,
              builder: (_, __) => Transform.rotate(
                angle: _spin.value * 2 * math.pi,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 1.5, sigmaY: 1.5),
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: SweepGradient(
                          colors: [coachAccent, warm, coachAccent]),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Atmender Kern
          Positioned.fill(
            left: 6,
            top: 6,
            right: 6,
            bottom: 6,
            child: ScaleTransition(
              scale: Tween(begin: 1.0, end: 1.06).animate(
                  CurvedAnimation(parent: _breathe, curve: Curves.easeInOut)),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    center: const Alignment(-0.36, -0.4),
                    colors: [
                      Color.lerp(coachAccent, Colors.white, 0.45)!,
                      coachAccent,
                    ],
                    stops: const [0, 0.75],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Konversation (AI Coach v2): User = coachAccent-Bubble rechts, Coach =
// Plain-Text links ohne Label.
// ---------------------------------------------------------------------------
class _Conversation extends StatelessWidget {
  const _Conversation({
    required this.controller,
    required this.focus,
    required this.messages,
    required this.sending,
  });

  final ScrollController controller;
  final FocusNode focus;
  final List<ChatMessage> messages;
  final bool sending;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('coach-message-list'),
      onTap: () => focus.unfocus(),
      behavior: HitTestBehavior.translucent,
      child: ListView.builder(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        itemCount: messages.length + (sending ? 1 : 0),
        itemBuilder: (context, i) {
          if (sending && i == messages.length) {
            return const _ThinkingRow();
          }
          return _MessageView(message: messages[i]);
        },
      ),
    );
  }
}

class _MessageView extends StatelessWidget {
  const _MessageView({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == ChatRole.user;
    final imageBytes = message.imageBytes;
    if (isUser) {
      return Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Flexible(
              child: Container(
                padding: EdgeInsets.fromLTRB(
                  15,
                  imageBytes == null ? 10 : 8,
                  15,
                  10,
                ),
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.78,
                ),
                decoration: BoxDecoration(
                  color: coachAccent,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (imageBytes != null) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(rCard),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            // Gepickte Bilder sind bis 1600px breit — Decode auf
                            // die Bubble-Breite begrenzen statt voll im Speicher.
                            final dpr = MediaQuery.devicePixelRatioOf(context);
                            final w = constraints.maxWidth.isFinite
                                ? constraints.maxWidth
                                : 320.0;
                            return Image.memory(
                              imageBytes,
                              height: 160,
                              width: double.infinity,
                              fit: BoxFit.cover,
                              cacheWidth: (w * dpr).round().clamp(1, 1600),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    Text(
                      message.content,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        height: 1.5,
                        letterSpacing: -0.1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    // Coach: Plain-Text ohne Bubble/Label (AI Coach v2); nur ein Refusal
    // bekommt eine kleine Hinweis-Zeile darueber.
    return Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.refusal) ...[
            const Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 12, color: warning),
                SizedBox(width: 5),
                Text(
                  'Hinweis',
                  style: TextStyle(
                    color: warning,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
          ],
          Text(
            message.content,
            style: const TextStyle(
              color: textPrimary,
              fontSize: 15,
              height: 1.5,
              letterSpacing: -0.1,
            ),
          ),
        ],
      ),
    );
  }
}

class _ThinkingRow extends StatefulWidget {
  const _ThinkingRow();
  @override
  State<_ThinkingRow> createState() => _ThinkingRowState();
}

class _ThinkingRowState extends State<_ThinkingRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 4),
      child: Row(
        children: [
          // RepaintBoundary: die Dauer-Animation (1,2s ..repeat()) haelt ihren
          // Re-Paint in einem eigenen Layer und invalidiert nicht die Chat-Liste.
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _c,
              builder: (_, __) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(3, (i) {
                    final phase = (_c.value + i * 0.18) % 1.0;
                    final t = math.sin(phase * math.pi).abs();
                    return Padding(
                      padding: EdgeInsets.only(right: i == 2 ? 0 : 5),
                      child: Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          color: textMuted.withValues(alpha: 0.28 + 0.55 * t),
                          shape: BoxShape.circle,
                        ),
                      ),
                    );
                  }),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, size: 16, color: warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: textPrimary,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Composer (AI Coach v2): rahmenlose Soft-Pill (surfaceSoft + cardShadow),
// "+"-Attach links, Text, Mic + runder Send-Kreis rechts (faerbt sich mit
// Draft in coachAccent). Fokus hellt die Flaeche dezent auf; bei knapper
// Quota sitzt ein tappbarer Hinweis-Pill darueber.
// ---------------------------------------------------------------------------
class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.focus,
    required this.enabled,
    required this.canSend,
    required this.remaining,
    required this.draft,
    required this.listening,
    required this.onSubmit,
    required this.onMic,
    required this.onAttach,
    required this.onQuotaTap,
  });

  final TextEditingController controller;
  final FocusNode focus;

  /// Tippen erlaubt (Session geladen, Quota uebrig).
  final bool enabled;

  /// Aktionen erlaubt (zusaetzlich: gerade kein Send unterwegs).
  final bool canSend;
  final int remaining;
  final String draft;
  final bool listening;
  final VoidCallback onSubmit;
  final VoidCallback onMic;
  final VoidCallback onAttach;
  final VoidCallback onQuotaTap;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  late bool _focused = widget.focus.hasFocus;

  @override
  void initState() {
    super.initState();
    widget.focus.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    widget.focus.removeListener(_handleFocusChange);
    super.dispose();
  }

  void _handleFocusChange() {
    if (_focused != widget.focus.hasFocus) {
      setState(() => _focused = widget.focus.hasFocus);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasText = widget.draft.trim().isNotEmpty;
    final showQuotaHint = widget.remaining > 0 && widget.remaining <= 2;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showQuotaHint)
            _QuotaHint(remaining: widget.remaining, onTap: widget.onQuotaTap),
          AnimatedContainer(
            duration: motionDuration(context, const Duration(milliseconds: 200)),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            constraints: const BoxConstraints(minHeight: 52, maxHeight: 160),
            padding: const EdgeInsets.fromLTRB(8, 4, 6, 4),
            decoration: BoxDecoration(
              // Rahmenlos: weiche, erhabene Kapsel im Premium-Dark-Stil
              // (cardShadow statt Stroke). Fokus hellt die Flaeche dezent auf,
              // statt einen Ring zu ziehen.
              color: _focused
                  ? Color.alphaBlend(
                      Colors.white.withValues(alpha: 0.045),
                      surfaceSoft,
                    )
                  : surfaceSoft,
              borderRadius: BorderRadius.circular(26),
              boxShadow: cardShadow,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _ComposerIcon(
                  key: const ValueKey('coach-attach'),
                  icon: Icons.add_rounded,
                  enabled: widget.canSend,
                  onTap: widget.onAttach,
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: TextField(
                    key: const ValueKey('coach-input'),
                    controller: widget.controller,
                    focusNode: widget.focus,
                    enabled: widget.enabled,
                    maxLines: 5,
                    minLines: 1,
                    textInputAction: TextInputAction.newline,
                    textCapitalization: TextCapitalization.sentences,
                    style: const TextStyle(
                      color: textPrimary,
                      fontSize: 15.5,
                      height: 1.3,
                      letterSpacing: -0.1,
                    ),
                    cursorColor: coachAccent,
                    decoration: InputDecoration(
                      isCollapsed: true,
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
                      hintText: widget.remaining <= 0
                          ? 'Limit für heute erreicht'
                          : widget.listening
                              ? 'Ich höre zu…'
                              : 'Frag FitPilot…',
                      hintStyle: const TextStyle(
                        color: textMuted,
                        fontSize: 15.5,
                        letterSpacing: -0.1,
                      ),
                      border: InputBorder.none,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                _MicButton(
                  enabled: widget.canSend,
                  listening: widget.listening,
                  onTap: widget.onMic,
                ),
                const SizedBox(width: 2),
                _SendButton(
                  active: hasText,
                  enabled: widget.canSend && hasText,
                  onTap: widget.onSubmit,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Dezenter Status-Pill ueber dem Composer, sobald nur noch 1–2 Coach-Fragen
/// uebrig sind. Tap oeffnet das Quota-Sheet.
class _QuotaHint extends StatelessWidget {
  const _QuotaHint({required this.remaining, required this.onTap});

  final int remaining;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Center(
        child: Material(
          key: const ValueKey('coach-quota-hint'),
          color: surfaceSoft,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: coachAccent,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    remaining == 1
                        ? 'Noch 1 Frage heute'
                        : 'Noch $remaining Fragen heute',
                    style: const TextStyle(
                      color: textMuted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.1,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ComposerIcon extends StatelessWidget {
  const _ComposerIcon({
    super.key,
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: enabled ? onTap : null,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 38,
            height: 44,
            child: Center(
              // Schlichtes Glyph ohne Chip (AI Coach v2) — die Pill selbst
              // traegt die Flaeche.
              child: Icon(
                icon,
                color: enabled ? textMuted : textMuted.withValues(alpha: 0.5),
                size: 20,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Mic-Button rechts im Composer. Waehrend [listening] pulsiert ein weicher
/// Akzent-Ring hinter dem Icon (unter "Bewegung reduzieren": statisch getoent).
class _MicButton extends StatefulWidget {
  const _MicButton({
    required this.enabled,
    required this.listening,
    required this.onTap,
  });

  final bool enabled;
  final bool listening;
  final VoidCallback onTap;

  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant _MicButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _syncPulse() {
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (widget.listening && !reduce) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      if (_pulse.isAnimating) _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final color = widget.listening
        ? coachAccent
        : (widget.enabled ? textMuted : textMuted.withValues(alpha: 0.5));
    return Padding(
      key: const ValueKey('coach-mic'),
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: widget.listening
            ? coachAccent.withValues(alpha: 0.14)
            : Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: widget.enabled ? widget.onTap : null,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 42,
            height: 44,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (widget.listening && !reduce)
                  RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _pulse,
                      builder: (_, __) {
                        final t = _pulse.value;
                        return Container(
                          width: 24 + 14 * t,
                          height: 24 + 14 * t,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: coachAccent.withValues(alpha: 0.5 * (1 - t)),
                              width: 1.5,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                Icon(Icons.mic_none_rounded, color: color, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Runder Send-Kreis (AI Coach v2): faerbt sich mit vorhandenem Draft in
/// coachAccent, sonst dezente Ruhe-Flaeche.
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.active,
    required this.enabled,
    required this.onTap,
  });

  final bool active;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
      child: GestureDetector(
        key: const ValueKey('coach-send'),
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: motionDuration(context, const Duration(milliseconds: 200)),
          curve: Curves.easeOutCubic,
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active && enabled
                ? coachAccent
                : textPrimary.withValues(alpha: 0.08),
          ),
          child: Icon(
            Icons.arrow_upward_rounded,
            color: active && enabled ? Colors.white : textMuted,
            size: 18,
          ),
        ),
      ),
    );
  }
}

/// Zeile im Attach-Sheet ("+"): Icon-Kachel + Label, Sheet-Pattern der App.
class _AttachTile extends StatelessWidget {
  const _AttachTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(rCard),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(rCard),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: surfaceSoft,
                  borderRadius: BorderRadius.circular(rControl),
                ),
                child: Icon(icon, size: 18, color: textPrimary),
              ),
              const SizedBox(width: 12),
              Text(
                label,
                style: const TextStyle(
                  color: textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sessions-Sheet: Liste aller Konversationen + "Neue Unterhaltung" oben.
// ---------------------------------------------------------------------------
class _SessionsSheet extends StatelessWidget {
  const _SessionsSheet({
    required this.sessions,
    required this.activeSessionId,
    required this.onNew,
    required this.onSelect,
    required this.onDelete,
  });

  final List<ChatSession> sessions;
  final String? activeSessionId;
  final VoidCallback onNew;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onDelete;

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.75;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 10, 0, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Coach-Sessions',
                        style: TextStyle(
                          color: textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      key: const ValueKey('coach-sessions-new'),
                      onPressed: onNew,
                      icon: const Icon(Icons.add_rounded,
                          size: 18, color: coachAccent),
                      label: const Text(
                        'Neu',
                        style: TextStyle(
                          color: coachAccent,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        backgroundColor: coachAccent.withValues(alpha: 0.10),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(rPill),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: sessions.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
                        child: Text(
                          'Noch keine Unterhaltungen. Stell deinem Coach die erste Frage.',
                          style: TextStyle(
                            color: textMuted.withValues(alpha: 0.9),
                            fontSize: 13.5,
                            height: 1.4,
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        shrinkWrap: true,
                        itemCount: sessions.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        itemBuilder: (context, i) {
                          final s = sessions[i];
                          final isActive = s.id == activeSessionId;
                          return _SessionTile(
                            session: s,
                            isActive: isActive,
                            onTap: () => onSelect(s.id),
                            onDelete: () => _confirmDelete(context, s),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, ChatSession s) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: surface,
        title: const Text('Session löschen?',
            style: TextStyle(color: textPrimary, fontSize: 16)),
        content: Text(
          '"${s.title}" und alle Nachrichten darin werden entfernt.',
          style: const TextStyle(color: textMuted, fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Abbrechen', style: TextStyle(color: textMuted)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              onDelete(s.id);
            },
            child: const Text('Löschen', style: TextStyle(color: danger)),
          ),
        ],
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.isActive,
    required this.onTap,
    required this.onDelete,
  });

  final ChatSession session;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isActive ? surfaceSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(rCard),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(rCard),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: isActive
                      ? coachAccent.withValues(alpha: 0.16)
                      : surfaceSoft,
                  borderRadius: BorderRadius.circular(rControl),
                ),
                child: Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 16,
                  color: isActive ? coachAccent : textMuted,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _humanizeTimestamp(session.lastMessageAt),
                      style: const TextStyle(color: textMuted, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Löschen',
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline_rounded,
                    size: 18, color: textMuted),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _humanizeTimestamp(DateTime ts) {
  final diff = DateTime.now().difference(ts);
  if (diff.inMinutes < 1) return 'gerade eben';
  if (diff.inMinutes < 60) return 'vor ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'vor ${diff.inHours} h';
  if (diff.inDays < 7) return 'vor ${diff.inDays} Tagen';
  return '${ts.day.toString().padLeft(2, '0')}.${ts.month.toString().padLeft(2, '0')}.${ts.year}';
}

// ---------------------------------------------------------------------------
class _QuotaBar extends StatelessWidget {
  const _QuotaBar({required this.remaining, required this.total});

  final int remaining;
  final int total;

  @override
  Widget build(BuildContext context) {
    final pct = total == 0 ? 0.0 : remaining / total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(rPill),
          child: Stack(
            children: [
              Container(height: 6, color: surfaceSoft),
              FractionallySizedBox(
                widthFactor: pct.clamp(0.0, 1.0),
                child: Container(
                  height: 6,
                  decoration: const BoxDecoration(color: coachAccent),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '$remaining / $total',
          style: const TextStyle(
            color: textPrimary,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
