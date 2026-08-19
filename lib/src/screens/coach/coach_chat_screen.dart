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
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../../models/chat_message.dart';
import '../../models/chat_session.dart';
import '../../models/coach_recipe_proposal.dart';
import '../../models/fitness_recipe.dart';
import '../../services/coach_chat_service.dart';
import '../../services/meal_photo_compressor.dart';
import '../../services/meal_photo_temp_file.dart';
import '../../services/recipe_image_store.dart';
import '../../services/sync_error_messages.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/common/motion.dart';
import '../../widgets/design/design.dart';
import '../today/today_texts.dart' show greetingForHour;

part 'coach_speech.dart';
part 'coach_top_bar.dart';
part 'coach_hero.dart';
part 'coach_orb.dart';
part 'coach_message_list.dart';
part 'coach_composer.dart';
part 'coach_recipe.dart';
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
    this.onCreateRecipe,
    this.userRecipeSlugs = const <String>{},
  });

  final CoachChatService? service;
  final String userName;

  /// Persistenz-Hook fuer /recipe-Vorschlaege — die Schale reicht
  /// `HomeStore.createUserRecipe` herein (derselbe 3-Netz-Pfad wie das
  /// manuelle Rezept-Formular). Der Coach selbst hat KEINE Rechte: der Hook
  /// laeuft ausschliesslich, nachdem der Nutzer im Sheet bestaetigt hat.
  /// null (Vorschau/Test ohne Sync): die Karte erscheint, der
  /// Hinzufuegen-Knopf bleibt ohne Wirkung deaktiviert.
  final Future<SyncDelivery> Function(FitnessRecipe recipe)? onCreateRecipe;

  /// Slugs der aktuell existierenden Eigen-Rezepte (Live-Sicht der Schale).
  /// Traegt den „Hinzugefuegt"-Zustand der Karten: er gilt nur, solange das
  /// erzeugte Rezept noch existiert — nach einem Loeschen im Rezepte-Tab
  /// wird der Button von selbst wieder aktiv.
  final Set<String> userRecipeSlugs;

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

class _CoachChatScreenState extends State<CoachChatScreen>
    with WidgetsBindingObserver {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocus = FocusNode();

  List<ChatMessage> _messages = const <ChatMessage>[];
  List<ChatSession> _sessions = const <ChatSession>[];

  /// Die zuletzt NICHT zugestellte Frage — Kennzeichnung und Wiederhol-Auftrag
  /// in einem. null heisst „alles, was im Verlauf steht, ist auch rausgegangen".
  ///
  /// Die Nachricht selbst bleibt im Verlauf stehen: sie ist Nutzerinhalt, und
  /// ihn aus der Liste zu nehmen hiesse, ihn zu verlieren, sobald ein zweiter
  /// Fehlschlag diesen Zeiger ueberschreibt. Nur EIN Auftrag wird gehalten —
  /// der juengste; ein aelterer verliert seine Kennzeichnung, seine Blase
  /// bleibt.
  _FehlgeschlageneSendung? _fehlgeschlagen;

  /// `null` heisst „ich weiss es nicht" — nicht „voll" und nicht „leer".
  ///
  /// Frueher stand hier `ChatQuotaSnapshot.unknown`, das mit `remaining: 5`
  /// belegt war. Jeder gescheiterte RPC hat damit ein erschoepftes Kontingent
  /// wieder aufgefuellt und die Sperre aufgehoben (Review D2). Ein Snapshot
  /// liegt jetzt nur vor, wenn der Server tatsaechlich Zahlen genannt hat.
  ChatQuotaSnapshot? _quota;
  String? _activeSessionId;
  bool _loading = true;
  bool _listening = false;
  String _draft = '';
  String? _error;

  /// Der Verlauf der aktiven Session war beim letzten Versuch nicht ladbar —
  /// dann darf der Hero-Leerzustand ihn nicht als „leer" praesentieren.
  bool _historyUnavailable = false;

  /// Ein Uebernehmen laeuft gerade (Bild ablegen + createUserRecipe) —
  /// sperrt alle Karten-Buttons, bis der Ausgang da ist.
  bool _addingRecipe = false;

  /// Wie viele Sende-Auftraege (Chat oder Rezept) gerade unterwegs sind.
  ///
  /// Frueher stand hier ein `bool _sending`, das [_switchToSession] beim
  /// Wechsel auf `false` zurueckstellte, damit die neue Sitzung nicht am
  /// Sende-Zustand der alten haengt. Damit liessen sich zwei Anfragen parallel
  /// absetzen: in A abschicken, wechseln, in B abschicken — zwei Tages-Slots
  /// aus einem Bedienschritt, und der Quota-Stand der verworfenen Antwort fiel
  /// weg, sodass die Anzeige weiter „5 frei" behauptete.
  ///
  /// Der Zaehler haengt am NUTZER, nicht an der Sitzung: das Kontingent tut
  /// das auch. Der Sitzungswechsel bleibt jederzeit moeglich (er ist keine
  /// Anfrage), er faelscht den Sende-Zustand nur nicht mehr — der Composer
  /// oeffnet wieder, sobald die laufende Anfrage einen Ausgang hat.
  ///
  /// Heruntergezaehlt wird ausschliesslich in [_sendevorgangBeendet], und das
  /// steht in einem `finally`: ein Auftrag, dessen Antwort wegen eines
  /// Sitzungswechsels verworfen wird, muss den Zaehler genauso freigeben wie
  /// ein erfolgreicher — sonst bliebe der Composer fuer immer gesperrt.
  int _laufendeSendungen = 0;

  bool get _sending => _laufendeSendungen > 0;

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
    WidgetsBinding.instance.addObserver(this);
    _input.addListener(() {
      if (_draft != _input.text) setState(() => _draft = _input.text);
    });
    // Kein Service = nicht eingeloggt: dieser Zweig braucht den lokalisierten
    // Fehlertext, und `Localizations.of()` (context.l10n) ist waehrend
    // initState() noch nicht erlaubt — [didChangeDependencies] uebernimmt ihn
    // unten, genau einmal, bevor der erste Frame baut.
    if (widget.service != null) {
      _bootstrap();
    }
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
  /// dort weg, faellt der Tab-Zweig hier still aus.
  ///
  /// Der Flankenwechsel allein deckt aber nur den Tab-WECHSEL ab, und genau
  /// daran haengt die Mitternachts-Aussperrung: wer den Coach-Tab oben liegen
  /// laesst und die App in den Hintergrund schickt, erzeugt beim Zurueckholen
  /// keine Flanke. Deshalb zieht [didChangeAppLifecycleState] denselben Pfad
  /// zusaetzlich beim Resume nach.
  bool _sichtbar = true;

  /// Setzt den lokalisierten „nicht eingeloggt"-Text genau einmal — nicht in
  /// [initState] (dort ist noch kein BuildContext fuer die Lokalisierung
  /// aufgebaut, s. `recipe_create_sheet.dart` fuer dasselbe Muster), aber
  /// auch nicht bei jedem [didChangeDependencies]-Aufruf (ein Locale-Wechsel
  /// WAEHREND der Screen ohne Service offen ist, soll den Text nicht erneut
  /// ueberschreiben — praktisch irrelevant hier, aber konsistent zum Muster).
  bool _notEingeloggtGemeldet = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.service == null && !_notEingeloggtGemeldet) {
      _notEingeloggtGemeldet = true;
      _loading = false;
      _error = context.l10n.coachErrorNotLoggedIn;
    }
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
  ///
  /// Zwei Aufrufer, weil einer nicht reicht: [didChangeDependencies] (Wechsel
  /// zurueck auf den Coach-Tab) und [didChangeAppLifecycleState] (die App
  /// kommt aus dem Hintergrund, waehrend der Coach-Tab schon oben liegt) —
  /// dasselbe Paar wie beim Tageswechsel des Stores (`home_store.dart:708`).
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

  /// Zweiter Ausloeser fuer den Nachziehpfad — [didChangeDependencies] allein
  /// haengt am Flankenwechsel des `TickerMode` und damit am TAB-Wechsel.
  ///
  /// Wer um 23:50 seinen letzten Tages-Slot verbraucht und die App AUF DEM
  /// COACH-TAB in den Hintergrund schickt, kommt am naechsten Morgen auf genau
  /// denselben Tab zurueck: der Ticker war nie aus, es gibt keine Flanke. Und
  /// weil bei erschoepftem Kontingent auch keine `send()`-Antwort mehr kommt,
  /// die den Zaehler korrigieren koennte, blieb der Composer bis zum Kaltstart
  /// gesperrt — ueber die Tagesgrenze hinweg, an der der Server laengst wieder
  /// Slots vergibt.
  ///
  /// Der Resume ist der Moment, in dem der Nutzer den Screen wieder ansieht;
  /// dieselben Schranken wie im Tab-Pfad gelten auch hier, damit ein Resume in
  /// einem anderen Tab keinen Request ausloest.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed) return;
    final svc = widget.service;
    if (!_sichtbar || svc == null || _loading) return;
    unawaited(_beiRueckkehr(svc));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    // Defensiv: `initState` ruft `_bootstrap()` seit der i18n-Migration nur
    // noch bei vorhandenem Service (der lokalisierte Fehlertext dafuer sitzt
    // in [didChangeDependencies] — `Localizations.of()` ist waehrend
    // initState() noch nicht erlaubt). `_beiRueckkehr` reicht ebenfalls immer
    // einen nicht-nullen Service durch — dieser Zweig ist also nur ein
    // Sicherheitsnetz und braucht deshalb kein `context.l10n` vor dem ersten
    // `await`.
    if (svc == null) return;
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
      // Nach mindestens einem `await`: Localizations ist jetzt sicher da.
      setState(() {
        _loading = false;
        _error = context.l10n.coachErrorNoSession;
      });
      return;
    }
    List<ChatMessage> history;
    try {
      history = await svc.loadHistory(activeId);
    } on CoachDataUnavailable {
      // „Nicht ladbar" ist nicht „leer": ein leeres _messages zeigte den
      // Hero-Leerzustand und praesentierte den Verlauf als geloescht.
      if (!mounted) return;
      setState(() {
        _loading = false;
        _historyUnavailable = true;
        _error = context.l10n.coachErrorHistoryUnavailable;
      });
      return;
    }
    _historyUnavailable = false;
    history = await _hydrateProposalImages(history);
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
      // Der Verlauf kommt frisch vom Server — ein Wiederhol-Auftrag auf eine
      // lokale Blase, die es jetzt nicht mehr gibt, waere ins Leere gerichtet.
      _fehlgeschlagen = null;
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

  /// Wechselt die angezeigte Unterhaltung.
  ///
  /// Jeder Ausgang prueft `_activeSessionId != sessionId` — derselbe Vergleich
  /// wie in [_send], nur mit dem ganzen Verlauf statt einer einzelnen Blase.
  /// `mounted` allein genuegt nicht: der Screen bleibt seit D6 dauerhaft
  /// gemountet, und zwei schnelle Wechsel A -> B -> C sind ein Wisch. Ohne den
  /// Vergleich schriebe der langsame Load von A seinen Verlauf in die Ansicht,
  /// waehrend oben C draufsteht — Chatverlaeufe unter fremdem Sitzungs-Label,
  /// und im Fehler-Arm sogar der Fehlerzustand einer laengst verlassenen
  /// Sitzung.
  Future<void> _switchToSession(String sessionId) async {
    final svc = widget.service;
    if (svc == null) return;
    if (_activeSessionId == sessionId) return;
    setState(() {
      _loading = true;
      _activeSessionId = sessionId;
      _messages = const <ChatMessage>[];
      // Die nicht zugestellte Frage gehoert der verlassenen Sitzung: ihre
      // Blase ist mit dem Verlauf weg, ihr Wiederhol-Auftrag wuerde sonst in
      // der neuen Sitzung landen.
      _fehlgeschlagen = null;
    });
    List<ChatMessage> history;
    try {
      history = await svc.loadHistory(sessionId);
    } on CoachDataUnavailable {
      // Auch der Fehler gehoert der Sitzung, die ihn ausgeloest hat: sonst
      // traegt C das Banner und den `_historyUnavailable`-Zustand von A.
      if (!mounted || _activeSessionId != sessionId) return;
      setState(() {
        _loading = false;
        _historyUnavailable = true;
        _error = context.l10n.coachErrorHistoryUnavailable;
      });
      return;
    }
    history = await _hydrateProposalImages(history);
    if (!mounted || _activeSessionId != sessionId) return;
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
    // Dieselbe Pruefung wie in [_switchToSession], nur gegen den Stand VOR dem
    // Anlegen: hat der Nutzer waehrenddessen die Sitzung gewechselt, gehoert
    // ihm die Ansicht — die frisch angelegte Sitzung steht in der Liste und
    // bleibt einen Tap entfernt.
    final vorher = _activeSessionId;
    final id = await svc.createSession();
    if (id == null) return;
    await _refreshSessions();
    if (!mounted || _activeSessionId != vorher) return;
    setState(() {
      _activeSessionId = id;
      _messages = const <ChatMessage>[];
      _error = null;
      _fehlgeschlagen = null;
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
        context.l10n.coachErrorDeleteFailed,
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
    // Bewusst NICHT ueber `_scroll.position`: [build] steckt den Verlauf in
    // einen AnimatedSwitcher (220 ms) und gibt jeder `_Conversation` denselben
    // Controller. Beim Sitzungswechsel (Verlauf -> Spinner -> Verlauf) haengen
    // deshalb kurzzeitig ZWEI ListViews daran — die ausblendende und die
    // eintretende. `position` ist `_positions.single` und wirft dann, und
    // `hasClients` faengt das nicht ab: es prueft nur, ob ueberhaupt eine
    // Liste angehaengt ist.
    //
    // Ans Ende gehoert ohnehin nur die zuletzt angehaengte: die ausblendende
    // ist im naechsten Frame weg, und sie mitzuziehen waere ein Ruckeln im
    // Uebergang.
    final positionen = _scroll.positions;
    if (positionen.isEmpty) return;
    final liste = positionen.last;
    // `maxScrollExtent` haelt ein `assert(hasContentDimensions)`: eine gerade
    // erst angehaengte Liste kennt ihre Ausmasse noch nicht. Im
    // Post-Frame-Callback ist das der Normalfall nicht, aber der Aufruf kommt
    // auch aus dem Sendepfad — und dort ist die Reihenfolge nicht garantiert.
    if (!liste.hasContentDimensions) return;
    final ziel = liste.maxScrollExtent + 240;
    final dauer = motionDuration(context, const Duration(milliseconds: 260));
    // Kein `animateTo(..., Duration.zero)`: DrivenScrollActivity haelt darauf
    // ein `assert(duration > Duration.zero)`. Unter reduzierter Bewegung
    // springt der Verlauf ans Ende, statt dorthin zu gleiten.
    if (dauer == Duration.zero) {
      liste.jumpTo(ziel.clamp(0.0, liste.maxScrollExtent));
      return;
    }
    liste.animateTo(ziel, duration: dauer, curve: Curves.easeOutCubic);
  }

  Future<void> _send({
    String? textOverride,
    Uint8List? imageBytes,
    String? imageMimeType,
  }) async {
    // Vor dem ersten `await` gegriffen: sicherer Context-Zugriff.
    final l10n = context.l10n;
    final svc = widget.service;
    final sessionId = _activeSessionId;
    final typedText = textOverride ?? _input.text;
    final text = typedText.trim();
    final hasImage = imageBytes != null && imageBytes.isNotEmpty;
    if (svc == null ||
        sessionId == null ||
        _sending ||
        (text.isEmpty && !hasImage)) {
      return;
    }
    // Der Service haelt bewusst keinen BuildContext (s. `coach_chat_service.dart`)
    // — hier, unmittelbar vor dem Sendeversuch, ist `l10n` frisch aus dem
    // Context gelesen und wird nur fuer die Fallback-Fehlertexte gebraucht.
    svc.l10n = l10n;
    // Nur ein bekanntermassen leeres Kontingent blockt hier. Ist der Stand
    // unbekannt, laeuft der Versuch bewusst zum Server — der weiss es genau
    // und antwortet notfalls mit 429 (-> CoachQuotaExceeded weiter unten).
    if (_kontingentErschoepft) {
      setState(
        () => _error = l10n.coachErrorDailyLimitReached(_limitFuerAnzeige),
      );
      return;
    }

    // Slash-Befehle (Nachtrag 2026-08-13: nur noch /recipe). Nur im reinen
    // Textfall — ein angehaengtes Foto ist eine normale Coach-Frage (z.B.
    // "was ist das?" mit Bild), kein Befehl. Ein UNBEKANNTER /-Befehl geht
    // nie ans Modell: das waere ein verbrannter Tages-Slot fuer einen Tippo.
    if (!hasImage && text.startsWith('/')) {
      final recipeWish = _recipeWishFrom(text);
      if (recipeWish == null) {
        setState(() => _error = l10n.coachCommandUnknownHint);
        return;
      }
      if (recipeWish.isEmpty) {
        // Ohne Wunschtext gibt es nichts zu generieren: lokaler Hinweis,
        // kein Request, kein Tages-Slot.
        setState(() => _error = l10n.coachRecipeEmptyHint);
        return;
      }
      await _sendRecipeRequest(
        svc: svc,
        sessionId: sessionId,
        wish: recipeWish,
        displayText: text,
        l10n: l10n,
      );
      return;
    }

    HapticFeedback.selectionClick();
    final displayText = text.isEmpty ? l10n.coachImageDefaultCaption : text;
    final userMsg = ChatMessage(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.user,
      content: displayText,
      createdAt: DateTime.now(),
      imageBytes: imageBytes,
    );
    final entwurf = _input.text;
    // Wiederhol-Auftrag fuer den Fehlerfall, VOR dem Request gebaut: dieselbe
    // Blase, derselbe Text, dasselbe Bild. [_wiederholen] nimmt die Nachricht
    // dann wieder aus dem Verlauf und schickt genau das erneut — statt eine
    // zweite Blase mit demselben Inhalt anzulegen.
    final auftrag = _FehlgeschlageneSendung(
      messageId: userMsg.id,
      text: displayText,
      imageBytes: imageBytes,
      imageMimeType: imageMimeType,
    );

    setState(() {
      _messages = [..._messages, userMsg];
      _input.clear();
      _draft = '';
      _laufendeSendungen++;
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
      // Der Tages-Slot ist auch dann verbraucht, wenn die Antwort gleich
      // verworfen wird — deshalb VOR dem Sitzungs-Vergleich.
      _quotaUebernehmen(remaining: res.remaining, dailyLimit: res.dailyLimit);
      // Antwort UND Fehler gehoeren der Sitzung, aus der die Frage kam. Der
      // Sitzungs-Knopf bleibt waehrend des Sendens bedienbar — ohne diesen
      // Vergleich landete die Antwort auf Sitzung A als Blase in Sitzung B,
      // ohne die zugehoerige Frage. `mounted` allein deckt das nicht ab: der
      // Screen bleibt seit D6 dauerhaft gemountet.
      if (!mounted || _activeSessionId != sessionId) return;
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
      });
      HapticFeedback.lightImpact();
      // Sessions im Hintergrund neu laden, damit Auto-Titel / last_message_at
      // im Sheet aktuell sind, ohne den Send-Flow zu blockieren.
      unawaited(_refreshSessions());
    } on CoachQuotaExceeded catch (e) {
      if (!mounted) return;
      // Der Server hat das Limit ausdruecklich genannt — belastbarer geht es
      // nicht, also ersetzt das jeden vorherigen Stand, egal welche Sitzung
      // inzwischen offen ist. Das Limit gilt dem Nutzer, nicht der Sitzung.
      setState(() {
        _quota = ChatQuotaSnapshot(
          used: e.dailyLimit,
          remaining: 0,
          dailyLimit: e.dailyLimit,
        );
      });
      if (_activeSessionId != sessionId) return;
      _entwurfZurueck(entwurf);
      // Auch hier gekennzeichnet: der Slot war schon weg, die Frage ist nicht
      // rausgegangen. Der Wiederhol-Knopf haengt an [_canInteract] und bleibt
      // bei erschoepftem Kontingent aus — die Kennzeichnung bleibt trotzdem,
      // sonst saehe die Blase aus wie abgeschickt.
      setState(() {
        _error = e.message;
        _fehlgeschlagen = auftrag;
      });
    } on CoachChatException catch (e) {
      if (!mounted || _activeSessionId != sessionId) return;
      _entwurfZurueck(entwurf);
      setState(() {
        _error = e.message;
        _fehlgeschlagen = auftrag;
      });
    } finally {
      // In JEDEM Ausgang — auch in den `return`s oben, in denen die Antwort
      // wegen eines Sitzungswechsels verworfen wird. Bliebe der Zaehler dort
      // stehen, waere der Composer bis zum Kaltstart gesperrt.
      _sendevorgangBeendet();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
  }

  /// Uebernimmt einen Kontingent-Stand, den der Server gerade genannt hat.
  ///
  /// Bewusst VOR dem Sitzungs-Vergleich aufgerufen: das Kontingent gehoert dem
  /// Nutzer, nicht der Sitzung. Wird die Antwort verworfen, weil inzwischen
  /// eine andere Unterhaltung offen ist, ist der Tages-Slot trotzdem weg — die
  /// Zahl mit der Antwort fallenzulassen hiesse, weiter „N frei" zu behaupten.
  ///
  /// Das Limit kommt seit E10 vom Server mit; nur aeltere Function-Deployments
  /// fallen auf den bisherigen Anzeige-Stand zurueck.
  void _quotaUebernehmen({required int? remaining, required int? dailyLimit}) {
    if (remaining == null || !mounted) return;
    final limit = dailyLimit ?? _limitFuerAnzeige;
    final frei = remaining.clamp(0, limit);
    setState(() {
      _quota = ChatQuotaSnapshot(
        used: limit - frei,
        remaining: frei,
        dailyLimit: limit,
      );
    });
  }

  /// Gegenstueck zu `_laufendeSendungen++`: gehoert in ein `finally`, damit
  /// wirklich jeder Ausgang zaehlt. Nach dem Unmount bleibt nur die reine
  /// Buchhaltung — ein setState waere dort ein Fehler.
  void _sendevorgangBeendet() {
    final rest = math.max(0, _laufendeSendungen - 1);
    if (!mounted) {
      _laufendeSendungen = rest;
      return;
    }
    setState(() => _laufendeSendungen = rest);
  }

  /// Wiederholt die zuletzt NICHT zugestellte Frage.
  ///
  /// Der Kern: die Nachricht wird zuerst aus dem Verlauf GENOMMEN und dann
  /// unveraendert neu abgeschickt — der Versuch ersetzt damit dieselbe Blase,
  /// statt eine zweite mit demselben Text anzulegen. Genau darueber machte ein
  /// Netzabbruch bisher aus einer Frage zwei: die Blase blieb als ganz normale
  /// Nachricht stehen, der zurueckgelegte Entwurf ging beim naechsten Tap auf
  /// „Senden" ein zweites Mal raus, und die Sitzung trug die Frage doppelt.
  ///
  /// Das Bild faehrt mit: es liegt nur lokal in der Blase (die Historie
  /// speichert bewusst keine Bilddaten), waere also nach einem Fehlschlag ohne
  /// diesen Auftrag verloren — der Nutzer muesste es neu auswaehlen.
  Future<void> _wiederholen() async {
    final auftrag = _fehlgeschlagen;
    if (auftrag == null || !_canInteract) return;
    // Der zurueckgelegte Entwurf gehoert zu genau dieser Nachricht und geht im
    // Wiederholversuch auf. Ein INZWISCHEN neu getippter Text ist dagegen ein
    // anderer und muss ueberleben: [_send] leert das Feld unbedingt, auch mit
    // `textOverride`.
    final fremderEntwurf =
        _input.text.trim() == auftrag.text.trim() ? '' : _input.text;
    setState(() {
      _messages = _messages
          .where((m) => m.id != auftrag.messageId)
          .toList(growable: false);
      _fehlgeschlagen = null;
      _error = null;
    });
    await _send(
      textOverride: auftrag.text,
      imageBytes: auftrag.imageBytes,
      imageMimeType: auftrag.imageMimeType,
    );
    if (mounted) _entwurfZurueck(fremderEntwurf);
  }

  /// Der getippte Text nach einem Fehlschlag zurueck ins Feld: gesendet wurde
  /// er nicht, und eine lange Frage nach einem Netzabbruch neu zu tippen ist
  /// der teuerste Weg, einen Fehler zu melden.
  ///
  /// Ein inzwischen NEU getippter Entwurf gewinnt: Tippen ist waehrend einer
  /// laufenden Antwort ausdruecklich erlaubt (s. [_canType]), und den gerade
  /// entstehenden Text zu ueberschreiben waere schlimmer als der Verlust des
  /// alten.
  void _entwurfZurueck(String entwurf) {
    if (entwurf.isEmpty || _input.text.isNotEmpty) return;
    _input.text = entwurf;
    _input.selection = TextSelection.collapsed(offset: entwurf.length);
  }

  /// Erkennt den /recipe-Befehl am Zeilenanfang (Nachtrag 2026-08-13:
  /// englisch als EINZIGE Schreibweise, in beiden App-Sprachen — die
  /// Discoverability uebernimmt das Befehls-Menue beim Tippen von "/").
  /// Liefert den Wunschtext ('' wenn nach dem Befehl nichts steht), sonst
  /// null (kein bzw. unbekannter Befehl).
  static String? _recipeWishFrom(String text) {
    final match = RegExp(
      r'^/recipe(?:\s+([\s\S]*))?$',
      caseSensitive: false,
    ).firstMatch(text.trim());
    if (match == null) return null;
    return (match.group(1) ?? '').trim();
  }

  /// Das Befehls-Menue erscheint, solange der Entwurf wie ein angefangener
  /// Befehl aussieht: beginnt mit "/", noch ohne Leerzeichen, und ist ein
  /// Praefix von "/recipe".
  bool get _commandMenuVisible {
    final draft = _draft.trimLeft();
    if (!draft.startsWith('/')) return false;
    if (draft.contains(' ') || draft.contains('\n')) return false;
    return '/recipe'.startsWith(draft.toLowerCase());
  }

  /// Tap auf einen Menue-Eintrag: Befehl samt trennendem Leerzeichen ins
  /// Feld, Cursor ans Ende — der Nutzer tippt direkt den Wunsch.
  void _applyCommand(String command) {
    HapticFeedback.selectionClick();
    _input.text = '$command ';
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    _inputFocus.requestFocus();
  }

  /// „Hinzugefügt" ist eine reine ABLEITUNG: der Karten-Slug ist
  /// deterministisch aus der Message-Id (FitnessRecipe.coachProposalSlug),
  /// die Live-Slugs kommen aus der Schale. Kein eigener Zustand — damit
  /// übersteht der Status App-Neustarts und Zweitgeräte, und Löschen im
  /// Rezepte-Tab reaktiviert den Button von selbst (Spec 2026-08-13).
  bool _isRecipeAdded(ChatMessage message) {
    if (message.recipeProposal == null) return false;
    return widget.userRecipeSlugs.contains(
      FitnessRecipe.coachProposalSlug(message.id),
    );
  }

  /// Reload-Karten (Nachtrag 2026-08-13): Proposals aus dem Verlauf kommen
  /// OHNE Bytes — hier die lokal abgelegten Vorschlagsbilder nachladen
  /// (RecipeImageStore, gekeyt an der Message-Id). Fehlende Dateien
  /// (Zweitgeraet, Cap-Prune, Logout dazwischen) bleiben Platzhalter.
  Future<List<ChatMessage>> _hydrateProposalImages(
    List<ChatMessage> history,
  ) async {
    final result = List<ChatMessage>.of(history);
    for (var i = 0; i < result.length; i++) {
      final message = result[i];
      final proposal = message.recipeProposal;
      if (proposal == null || proposal.imageBytes != null) continue;
      final bytes = await RecipeImageStore.instance.readProposalImage(
        message.id,
      );
      if (bytes == null) continue;
      result[i] = ChatMessage(
        id: message.id,
        role: message.role,
        content: message.content,
        createdAt: message.createdAt,
        refusal: message.refusal,
        recipeProposal: proposal.withImageBytes(bytes),
      );
    }
    return result;
  }

  /// Spiegel von [_send] fuer den Rezept-Pfad: optimistische User-Blase mit
  /// der Original-Eingabe (inkl. Befehl), dann requestRecipe. Die Antwort
  /// wird zur Assistant-Nachricht MIT [ChatMessage.recipeProposal] — die
  /// Karte lebt nur in dieser Session, der Verlauf traegt die
  /// Text-Zusammenfassung (reply).
  Future<void> _sendRecipeRequest({
    required CoachChatService svc,
    required String sessionId,
    required String wish,
    required String displayText,
    required AppLocalizations l10n,
  }) async {
    HapticFeedback.selectionClick();
    final userMsg = ChatMessage(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      role: ChatRole.user,
      content: displayText,
      createdAt: DateTime.now(),
    );
    final entwurf = _input.text;
    // Wie in [_send]: [displayText] traegt den Befehl mit („/recipe …"), der
    // Wiederholversuch laeuft deshalb von selbst wieder in diesen Zweig.
    final auftrag = _FehlgeschlageneSendung(
      messageId: userMsg.id,
      text: displayText,
    );
    setState(() {
      _messages = [..._messages, userMsg];
      _input.clear();
      _draft = '';
      _laufendeSendungen++;
      _error = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());

    try {
      final res = await svc.requestRecipe(
        wish,
        sessionId: sessionId,
        locale: l10n.localeName,
        userContext: widget.userContext,
      );
      // Wie in [_send]: der Slot ist verbraucht, auch wenn die Karte gleich
      // verworfen wird.
      _quotaUebernehmen(remaining: res.remaining, dailyLimit: res.dailyLimit);
      // Sitzungs-Vergleich wie in [_send]: die Karte gehoert der Sitzung, aus
      // der der Wunsch kam.
      if (!mounted || _activeSessionId != sessionId) return;
      // Reload-Karte (Nachtrag 2026-08-13): das Bild unter der SERVER-
      // Message-Id lokal ablegen — dieselbe Id traegt die Nachricht, damit
      // Verlaufs-Rekonstruktion und Live-Karte denselben Schluessel nutzen.
      final serverId = res.assistantMessageId;
      final imageBytes = res.proposal?.imageBytes;
      if (serverId != null && imageBytes != null) {
        unawaited(
          RecipeImageStore.instance.saveProposalImage(
            messageId: serverId,
            bytes: imageBytes,
          ),
        );
      }
      setState(() {
        _messages = [
          ..._messages,
          ChatMessage(
            id: serverId ?? 'local-r-${DateTime.now().microsecondsSinceEpoch}',
            role: ChatRole.assistant,
            content: res.reply,
            createdAt: DateTime.now(),
            refusal: res.refusal,
            recipeProposal: res.proposal,
          ),
        ];
      });
      HapticFeedback.lightImpact();
      unawaited(_refreshSessions());
    } on CoachQuotaExceeded catch (e) {
      if (!mounted) return;
      // Wie in [_send]: das Limit gilt dem Nutzer, nicht der Sitzung.
      setState(() {
        _quota = ChatQuotaSnapshot(
          used: e.dailyLimit,
          remaining: 0,
          dailyLimit: e.dailyLimit,
        );
      });
      if (_activeSessionId != sessionId) return;
      _entwurfZurueck(entwurf);
      setState(() {
        _error = e.message;
        _fehlgeschlagen = auftrag;
      });
    } on CoachChatException catch (e) {
      if (!mounted || _activeSessionId != sessionId) return;
      _entwurfZurueck(entwurf);
      setState(() {
        _error = e.message;
        _fehlgeschlagen = auftrag;
      });
    } finally {
      _sendevorgangBeendet();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
  }

  /// Uebernehmen eines /rezept-Vorschlags — der EINZIGE Weg, auf dem aus
  /// einer Coach-Antwort je etwas gespeichert wird, und er laeuft komplett
  /// clientseitig ueber den nutzerbestaetigten [CoachChatScreen.onCreateRecipe]-
  /// Hook (Sheet -> Bild lokal ablegen -> createUserRecipe).
  Future<void> _addProposalToRecipes(ChatMessage message) async {
    final proposal = message.recipeProposal;
    final onCreate = widget.onCreateRecipe;
    if (proposal == null || onCreate == null || _addingRecipe) return;
    if (_isRecipeAdded(message)) return;
    HapticFeedback.selectionClick();
    final confirmed = await showEatovaSheet<bool>(
      context,
      _RecipeAddSheet(proposal: proposal),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _addingRecipe = true);
    var imageAsset = '';
    final bytes = proposal.imageBytes;
    if (bytes != null) {
      final referenz = await RecipeImageStore.instance.save(bytes: bytes);
      if (!mounted) return;
      if (referenz == null) {
        // Wie im manuellen Formular: das Rezept kommt trotzdem, nur ohne
        // Bild — der Nutzer erfaehrt es.
        showAppSnack(
          context,
          context.l10n.recipesPhotoSaveFailedError,
          icon: Icons.error_outline_rounded,
          tone: SnackTone.error,
        );
      } else {
        imageAsset = referenz;
      }
    }

    final recipe = proposal.toFitnessRecipe(
      imageAsset: imageAsset,
      slug: FitnessRecipe.coachProposalSlug(message.id),
    );
    // Luecke-E-Muster (recipes_screen): die Meldung wartet auf den Ausgang,
    // statt ihn zu behaupten — der Store deckelt die Wartezeit.
    final ausgang = await onCreate(recipe);
    if (!mounted) return;
    setState(() {
      _addingRecipe = false;
    });
    HapticFeedback.lightImpact();
    showAppSnack(
      context,
      deliveryHint(
        context.l10n.recipesSavedSuccess(recipe.title),
        ausgang,
        context.l10n,
      ),
      icon: Icons.bookmark_added_rounded,
    );
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
    // Vor dem ersten `await` gegriffen: sicherer Context-Zugriff.
    final l10n = context.l10n;
    // Die Kopie, die der Picker im App-Cache anlegt — sie wird im `finally`
    // wieder geloescht. Ohne das bleiben Essens- und Fortschrittsfotos des
    // Nutzers unbegrenzt auf dem Geraet liegen, auch nach der Kontoloeschung.
    XFile? aufnahme;
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
      aufnahme = image;
      final raw = await image.readAsBytes();
      final bytes = await _scrubImage(raw);
      if (!mounted) return;
      if (bytes.lengthInBytes > _maxImageBytes) {
        setState(() => _error = l10n.coachErrorImageTooLarge);
        return;
      }
      await _send(
        textOverride: _input.text.trim().isEmpty
            ? l10n.coachImageDefaultCaption
            : _input.text.trim(),
        imageBytes: bytes,
        imageMimeType: _mimeForBytes(bytes, image),
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _error = _permissionMessageFor(source, e, l10n));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = l10n.coachErrorImageLoadFailed);
    } finally {
      // Erst hier: die Bytes sind zu diesem Zeitpunkt gelesen, gescrubbt und
      // verschickt — der Pfad wird danach nur noch fuer den MIME-Typ gebraucht,
      // nicht mehr der Inhalt.
      final datei = aufnahme;
      if (datei != null) await deleteMealPhotoTempFile(datei.path);
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

  String _permissionMessageFor(
    ImageSource source,
    PlatformException e,
    AppLocalizations l10n,
  ) {
    final permissionText = source == ImageSource.camera
        ? l10n.coachCameraAccessNoun
        : l10n.coachPhotoAccessNoun;
    final lower = '${e.code} ${e.message}'.toLowerCase();
    if (lower.contains('denied') || lower.contains('permission')) {
      return l10n.coachPermissionDenied(permissionText);
    }
    return l10n.coachErrorImageOpenFailed;
  }

  Future<void> _toggleSpeechInput() async {
    if (!_canInteract) return;
    HapticFeedback.selectionClick();
    if (_listening) {
      await widget.speechInput.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }

    // Vor dem ersten `await` gegriffen: sicherer Context-Zugriff.
    final l10n = context.l10n;
    setState(() {
      _listening = true;
      _error = null;
    });
    try {
      // Diktat-Locale folgt der App-Sprache statt hart 'de_DE' (Scan/Coach-PR,
      // 2026-08-11): 'en' -> 'en_US', jede andere/unbekannte Sprache bleibt
      // 'de_DE' — derselbe Fallback wie ueberall sonst in dieser Runde.
      final speechLocaleId = l10n.localeName == 'en' ? 'en_US' : 'de_DE';
      final spokenText = await widget.speechInput.listen(
        localeId: speechLocaleId,
        l10n: l10n,
      );
      if (!mounted) return;
      setState(() => _listening = false);
      final text = spokenText?.trim() ?? '';
      if (text.isEmpty) {
        setState(() => _error = l10n.coachErrorSpeechEmpty);
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
        _error = l10n.coachSpeechUnavailable;
      });
    }
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
                  label: sheetContext.l10n.coachAttachCamera,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _pickAndSendImage(ImageSource.camera);
                  },
                ),
                const SizedBox(height: 6),
                _AttachTile(
                  key: const ValueKey('coach-gallery'),
                  icon: Icons.photo_outlined,
                  label: sheetContext.l10n.coachAttachGallery,
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
    final quota = _quota;
    showEatovaSheet<void>(
      context,
      // Nur ein echter Snapshot darf Zahlen zeigen: [_restFuerAnzeige] haette
      // hier nach einem gescheiterten Quota-RPC das Standardlimit eingesetzt
      // und daraus „5 von 5 Fragen heute frei" gemacht.
      quota == null
          ? const _CoachInfoSheetUnbekannt()
          : _CoachInfoSheet(
              remaining: quota.remaining.clamp(0, quota.dailyLimit),
              dailyLimit: quota.dailyLimit,
            ),
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
            duration: motionDuration(
              context,
              const Duration(milliseconds: 220),
            ),
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
                  )
                : _Conversation(
                    controller: _scroll,
                    focus: _inputFocus,
                    messages: _messages,
                    sending: _sending,
                    recipeAddedFor: _isRecipeAdded,
                    // Ohne Hook (Vorschau/Test ohne Sync) und waehrend
                    // eines laufenden Uebernehmens bleiben die
                    // Karten-Buttons deaktiviert.
                    recipeAddEnabled:
                        widget.onCreateRecipe != null && !_addingRecipe,
                    onAddRecipe: _addProposalToRecipes,
                  ),
          ),
        ),
        // Direkt unter dem Verlauf und damit unmittelbar an der Blase, um die
        // es geht: die fehlgeschlagene Frage ist die letzte im Verlauf.
        if (_fehlgeschlagen != null)
          _UnsentNotice(canRetry: _canInteract, onRetry: _wiederholen),
        if (_error != null) _ErrorBanner(text: _error!),
        // Befehls-Menue (Nachtrag 2026-08-13): erscheint beim Tippen von "/"
        // direkt ueber dem Composer; Tap vervollstaendigt den Befehl.
        if (_commandMenuVisible) _CommandSuggestions(onPick: _applyCommand),
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

/// Ein Sendeversuch, der den Server nie erreicht hat — Kennzeichnung UND
/// Wiederhol-Auftrag.
///
/// Haelt bewusst alles, was der zweite Versuch braucht, statt ihn aus dem
/// Eingabefeld zu rekonstruieren: [text] ist der angezeigte Text (beim
/// Bild-Fall die Standard-Bildunterschrift, beim Rezept-Fall inklusive
/// „/recipe"), [imageBytes] das bereits gescrubbte Bild. Nur so bleibt der
/// Wiederholversuch BITGLEICH — und kostet nicht noch einmal Auswahl,
/// Kompression und EXIF-Scrub.
class _FehlgeschlageneSendung {
  const _FehlgeschlageneSendung({
    required this.messageId,
    required this.text,
    this.imageBytes,
    this.imageMimeType,
  });

  /// Id der Blase im Verlauf. Der Wiederholversuch nimmt genau sie heraus —
  /// deshalb entsteht keine zweite.
  final String messageId;

  final String text;
  final Uint8List? imageBytes;
  final String? imageMimeType;
}

/// „Nicht gesendet" unter dem Verlauf, mit dem Wiederhol-Knopf daneben.
///
/// Rechtsbuendig wie die Nutzer-Blasen: der Fehlerzustand gehoert der EIGENEN
/// Nachricht. Ohne diese Zeile sah eine nie abgeschickte Frage exakt aus wie
/// eine zugestellte — der einzige Weg zurueck war „nochmal tippen", und der
/// erzeugte eine zweite Blase mit demselben Inhalt.
///
/// Der Knopf verschwindet, statt deaktiviert dazustehen, wenn gerade nichts
/// gesendet werden kann (laufende Anfrage, erschoepftes Kontingent): ein
/// wirkungsloser Knopf ist eine Aufforderung, die nicht eingeloest wird. Die
/// Kennzeichnung bleibt in beiden Faellen.
class _UnsentNotice extends StatelessWidget {
  const _UnsentNotice({required this.canRetry, required this.onRetry});

  final bool canRetry;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Padding(
      key: const ValueKey('coach-unsent'),
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          Icon(Icons.error_outline_rounded, size: 13, color: t.warning),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              l10n.coachMessageNotSent,
              style: AppType.ui(
                11.5,
                weight: FontWeight.w600,
                color: t.warning,
              ),
            ),
          ),
          if (canRetry) ...<Widget>[
            const SizedBox(width: 6),
            Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(rPill),
              child: InkWell(
                key: const ValueKey('coach-unsent-retry'),
                onTap: onRetry,
                borderRadius: BorderRadius.circular(rPill),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.refresh_rounded, size: 14, color: t.accent),
                      const SizedBox(width: 5),
                      Text(
                        l10n.coachMessageRetry,
                        style: AppType.ui(
                          11.5,
                          weight: FontWeight.w700,
                          color: t.accent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// (i)-Sheet fuer den Fall „Tageskontingent unbekannt" — Zwilling von
/// [_CoachInfoSheet] ohne dessen Zahlenteil.
///
/// [_CoachInfoSheet] nimmt zwei `int` und kann den Fall deshalb gar nicht
/// darstellen: liegt kein Snapshot vor, bekaeme es
/// [ChatQuotaSnapshot.standardTageslimit] gereicht und behauptete nach einem
/// gescheiterten Quota-RPC „5 von 5 Fragen heute frei" — samt vollem Balken.
/// Genau das ist die Anzeige-Haelfte der Luege, die Migration 20260808210000
/// (chat_quota_honesty) serverseitig abstellt: ein Nutzer mit verbrauchtem
/// Kontingent liest sonst ausgerechnet dann „alles frei", wenn die App nichts
/// weiss. Eine falsche Zahl, die praezise aussieht, ist schaedlicher als eine
/// fehlende.
///
/// Deshalb hier eine zahlenlose Zeile und KEIN Balken: ein leerer Balken laese
/// sich als „verbraucht" lesen, ein voller als „alles frei" — beides waere
/// wieder eine Behauptung.
///
/// Der C8-Offenlegungsteil ist bewusst derselbe wie im Zwilling; seine Texte
/// kommen aus denselben l10n-Keys, eine Textaenderung wirkt hier wie dort.
/// Zusammenlegen liesse sich beides nur ueber die Signatur von
/// [_CoachInfoSheet] (nullable Snapshot statt zwei `int`) — das ist ein
/// Eingriff in `coach_composer.dart` und steht als einziger Punkt aus.
///
/// Bis dahin sind es zwei Bauplaene fuer denselben, datenschutzrechtlich
/// relevanten Block. Damit eine kuenftige Aenderung nicht nur eine der beiden
/// Kopien erreicht, prueft `test/coach_ai_disclosure_test.dart` BEIDE
/// Fassungen gegen dieselbe Liste von l10n-Keys: wer hier eine Zeile
/// hinzufuegt, entfernt oder umsortiert, ohne den Zwilling nachzuziehen,
/// bekommt genau einen roten Test.
class _CoachInfoSheetUnbekannt extends StatelessWidget {
  const _CoachInfoSheetUnbekannt();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            key: const ValueKey('coach-info-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                l10n.coachTitle,
                style:
                    AppType.display(20, weight: FontWeight.w700, color: t.ink),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.coachInfoIntro,
                style: AppType.ui(13, color: t.ink2, height: 1.45),
              ),
              const SizedBox(height: 18),
              _InfoLabel(l10n.coachInfoDataLabel),
              const SizedBox(height: 8),
              _InfoBullet(l10n.coachInfoBulletWeight),
              _InfoBullet(l10n.coachInfoBulletMacros),
              _InfoBullet(l10n.coachInfoBulletMeals),
              const SizedBox(height: 12),
              Text(
                l10n.coachInfoProvider,
                style: AppType.ui(13, color: t.ink2, height: 1.45),
              ),
              const SizedBox(height: 20),
              Container(height: 1, color: t.line),
              const SizedBox(height: 18),
              _InfoLabel(l10n.coachInfoLimitLabel),
              const SizedBox(height: 6),
              Text(
                l10n.coachInfoLimitUnknown,
                key: const ValueKey('coach-info-limit-unbekannt'),
                style: AppType.ui(13, color: t.ink2, height: 1.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
