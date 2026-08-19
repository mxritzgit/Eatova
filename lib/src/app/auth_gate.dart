import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../screens/auth_screen.dart';
import '../services/crash_reporter.dart';
import '../services/local_cache.dart';
import '../services/recipe_image_store.dart';
import '../widgets/common/app_snack.dart';

/// Merker fuer die GEWOLLTE Abmeldung.
///
/// Warum ueberhaupt: [_AuthGateState._onAuthEvent] sieht nur, DASS die
/// Identitaet gewechselt hat, nie WARUM. Bis zum Review 2026-08-19 zog der Gate
/// die Grenze an „lag noch etwas ueber der Root-Route" — das stimmte genau so
/// lange, wie der Ausloggen-Knopf selbst poppte, BEVOR er `signOut` rief. Seit
/// er in den Einstellungen sitzt (2026-08-10), also auf einer gepushten Route,
/// raeumt der Gate beim gewollten Logout sehr wohl Routen ab und behauptete
/// anschliessend „Deine Sitzung ist abgelaufen" — ausgerechnet dem Nutzer
/// gegenueber, der sich gerade selbst abgemeldet hat.
///
/// Die Absicht verfaellt nach [gueltigkeit]: bleibt der Abmelde-Versuch
/// stecken (Netzfehler, gar kein Auth-Ereignis), darf er nicht Stunden spaeter
/// einen ECHTEN Sitzungsverlust stumm schalten.
abstract final class IntentionalSignOut {
  /// So lange gilt eine Absichtserklaerung. Grosszuegig genug fuer
  /// Cache-Raeumung + Server-Roundtrip von `signOut`, kurz genug, dass ein
  /// steckengebliebener Versuch nicht die naechste Sitzung stumm schaltet.
  static const Duration gueltigkeit = Duration(seconds: 30);

  static DateTime? _markiertAm;

  /// Der Logout-Pfad meldet seine Absicht an, BEVOR er `signOut` ruft — das
  /// Auth-Ereignis kann dem Aufruf dicht auf den Fersen sein.
  static void mark() => _markiertAm = clock.now();

  /// Nimmt die Absicht zurueck: die Abmeldung ist gar nicht erst zustande
  /// gekommen, es gibt also nichts mehr zu erklaeren.
  static void clear() => _markiertAm = null;

  /// Liest die Absicht und VERBRAUCHT sie — jede gilt fuer genau einen
  /// Auth-Uebergang.
  static bool consume() {
    final markiert = _markiertAm;
    _markiertAm = null;
    return markiert != null &&
        clock.now().difference(markiert) < gueltigkeit;
  }
}

/// Raeumt den personenbezogenen Cache-Namensraum eines abgeloesten Nutzers.
///
/// Warum hier und nicht (nur) in `HomeStore.signOutCleanup`: die dortige
/// Raeumung haengt am Ausloggen-Knopf in den Einstellungen. Ein
/// UNFREIWILLIGES Sitzungsende (Passwortwechsel auf einem anderen Geraet,
/// serverseitiger Widerruf, abgelaufener Refresh-Token) und der direkte
/// Wechsel A -> B kommen dort nie an — Profil, Lebenszeit-Zaehler, Tagebuch,
/// Favoriten, Gewichtsreihe und das Erinnerungs-Flag von A blieben auf dem
/// Geraet liegen (Audit M-1 gilt fuer sie unveraendert).
///
/// [LocalCache.clear] laeuft mit `preserveOutbox: true`: Outbox und pendende
/// Stats-Deltas sind KEIN Anzeige-Cache, sondern nicht zugestellte
/// Schreibvorgaenge. Sie zu vernichten hiesse, dem Nutzer die im Flugzeug
/// geloggten Mahlzeiten zu nehmen (A2). Beide Slots sind verschluesselt und
/// nach User-ID getrennt (`eatova.v1.outbox.<uid>`, s. local_cache.dart) und
/// spielen beim naechsten Login DESSELBEN Kontos nach.
Future<void> purgePersonalCacheFor(String userId) async {
  if (userId.isEmpty) return;
  try {
    final cache = await LocalCache.create(userId);
    if (cache != null) await purgePersonalCache(cache);
  } catch (e, st) {
    // Best effort: ein nicht raeumbarer Cache darf den Auth-Uebergang nicht
    // aufhalten. Gemeldet wird er trotzdem — er ist der Grund, warum
    // Gesundheitsdaten liegen bleiben.
    unawaited(CrashReporter.capture(e, st, context: 'auth-gate-cache-purge'));
  }
}

/// Die Raeumung selbst — getrennt vom Bauen des Caches, damit sie ohne
/// SharedPreferences-Kanal und OS-Keystore pruefbar bleibt (`LocalCache.create`
/// liefert im Test null, der Purge waere sonst nicht beobachtbar).
@visibleForTesting
Future<void> purgePersonalCache(LocalCache cache) =>
    cache.clear(preserveOutbox: true);

class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.authRepository,
    required this.builder,
    this.debugPurgeCache,
  });

  final AuthRepository authRepository;

  /// Test-Seam fuer [purgePersonalCacheFor]: der echte Weg braucht den
  /// SharedPreferences-Kanal und den OS-Keystore, die es im Widget-Test nicht
  /// gibt (`LocalCache.create` liefert dort null und der Purge waere nicht
  /// beobachtbar). In Production immer null.
  @visibleForTesting
  final Future<void> Function(String userId)? debugPurgeCache;

  /// Builder bekommt den User UND ein Flag ob das eine frische
  /// Anmeldung in dieser App-Session war. Damit kann die HomePage
  /// die Welcome-Animation NUR bei tatsaechlichem Login/Register zeigen,
  /// nicht bei jedem Kaltstart mit gueltiger Session.
  final Widget Function(
    BuildContext context,
    EatovaUser user,
    bool freshLogin,
  ) builder;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<EatovaUser?>? _subscription;
  EatovaUser? _user;
  bool _freshLogin = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.authRepository.currentUser;
    _user = initial;
    // Session-Restore bei App-Start zaehlt nicht als fresh login.
    _freshLogin = false;
    // Finding 5 (Security-Review 2026-08-11): der Rezept-Foto-Store ist an
    // die aktive User-ID gebunden. Der Kaltstart bindet den restaurierten
    // Nutzer (null -> uid purgt nichts, s. setActiveUser) — alle SPAETEREN
    // Uebergaenge laufen durch _onAuthEvent.
    unawaited(RecipeImageStore.instance.setActiveUser(initial?.id));
    _subscription = widget.authRepository.authStateChanges
        .listen(_onAuthEvent, onError: _onAuthStreamError);
  }

  /// Der Auth-Strom fuehrt FEHLER, nicht nur Werte.
  ///
  /// gotrue speist sie aktiv ein (`notifyException` bei
  /// `AuthRetryableFetchException`, `addError` auf dem eigenen Controller).
  /// Ohne `onError` landete so ein Fehler als unbehandelter Zonen-Fehler — von
  /// aussen ausloesbar (der BROWSABLE-Deeplink-Intent fuehrt in
  /// `getSessionFromUrl`) und dank Sentry auch noch als gemeldeter Absturz.
  ///
  /// Behandelt heisst hier: melden und weiterleben. Der Gate hat nichts zu
  /// tun — ein wirklich verlorener Token kommt als regulaeres `null`-Ereignis
  /// nach, ein voruebergehender Netzfehler geht von selbst vorbei. Der Nutzer
  /// bekommt bewusst KEINE Meldung: er hat nichts angestossen, und ein Toast
  /// waere von aussen ausloesbar.
  ///
  /// `captureSyncFailure` statt `capture`: ein Netzausfall auf dem
  /// Token-Refresh ist der vorgesehene Ablauf, kein Vorfall — dieselbe
  /// Abwaegung wie im Sync-Pfad (s. crash_reporter.dart). Was ueberhaupt
  /// hinausgeht, entscheidet dort `sanitizeForReport`, nicht diese Stelle.
  void _onAuthStreamError(Object error, StackTrace stack) {
    unawaited(CrashReporter.captureSyncFailure(error, stack,
        context: 'auth-state-stream'));
  }

  void _onAuthEvent(EatovaUser? user) {
    // Finding 5: der Gate ist die EINE Stelle, durch die jeder Auth-Uebergang
    // laeuft — auch unfreiwilliger Session-Verlust und der direkte Wechsel
    // A -> B, die kein signOutCleanup sehen. Deshalb haengt die Bindung des
    // Foto-Stores hier, VOR dem mounted-Check (auch ein Event waehrend des
    // Abbaus muss den Wechsel purgen) und vor dem setState (kein Frame des
    // neuen Kontos sieht den alten Namensraum; der Namensraum wechselt in
    // setActiveUser synchron, nur das Purgen des Vorgaengers laeuft nach —
    // erreichbar ist der ab dem Wechsel ohnehin nicht mehr). Ein
    // Token-Refresh (dieselbe id) ist dort ein No-Op.
    unawaited(RecipeImageStore.instance.setActiveUser(user?.id));
    final previous = _user;
    // NUR beim echten Identitaetswechsel: ein Token-Refresh liefert denselben
    // Nutzer erneut.
    final identityChanged =
        previous != null && (user == null || user.id != previous.id);
    if (identityChanged) {
      // Review 2026-08-19: derselbe Grund, aus dem der Foto-Store hier haengt,
      // gilt fuer den durablen Cache. `HomeStore.signOutCleanup` raeumt Profil,
      // Lebenszeit-Zaehler, Tagebuch, Favoriten, Gewicht und das
      // Erinnerungs-Flag — erreichbar ist es aber nur ueber den
      // Ausloggen-Knopf. Beim externen Session-Verlust und beim direkten
      // Wechsel A -> B blieben die Slots von A auf dem Geraet liegen.
      // Ungeawaitet und wie die Foto-Bindung VOR dem mounted-Check: auch ein
      // Ereignis waehrend des Abbaus muss den Bestand des Vorgaengers raeumen.
      unawaited((widget.debugPurgeCache ?? purgePersonalCacheFor)(previous.id));
    }
    if (!mounted) return;
    final wasLoggedOut = previous == null;
    final isLoggedIn = user != null;

    // D8: AuthGate ist der Inhalt von MaterialApp.home, also der Root-Route.
    // Ein Auth-Wechsel tauschte bisher NUR diesen Inhalt â€” alles was der
    // Nutzer darueber gepusht hat (Profil, Trends, ein Dialog, ein Bottom
    // Sheet) blieb sichtbar und voll bedienbar und zeigte Daten einer Session,
    // die es nicht mehr gibt. Beim externen Session-Verlust (Passwortaenderung
    // auf einem anderen Geraet, serverseitiger Widerruf) also den
    // Navigator-Stack mit abraeumen. Wieder nur beim echten
    // Identitaetswechsel: ein Token-Refresh darf die offene Ansicht nicht
    // wegraeumen.
    if (identityChanged) {
      // Verbraucht wird die Absicht IMMER, nicht nur im Melde-Zweig: sie gilt
      // fuer genau einen Uebergang und darf keinen spaeteren erklaeren.
      final gewollt = IntentionalSignOut.consume();
      _popToRootRoute();
      // Wortlos auf dem Login zu landen, waehrend man gerade sein Profil
      // ansah, ist verwirrend â€” der Grund gehoert dazu. Der Hinweis haengt
      // hier und nicht im AuthScreen, weil nur der Gate den Unterschied
      // zwischen â€žabgemeldet" und â€žSitzung verloren" kennt; die Snackbar
      // laeuft ueber den ScaffoldMessenger der MaterialApp und wird vom
      // Scaffold des AuthScreens gezeigt, sobald der gebaut ist.
      //
      // Die Abgrenzung zur gewollten Abmeldung ist [IntentionalSignOut] und
      // NICHT mehr „es lag etwas ueber der Root-Route": diese Begruendung
      // zielte auf einen Ausloggen-Knopf, der selbst poppte, bevor er signOut
      // rief. Seit er in den Einstellungen sitzt, raeumt auch der gewollte
      // Logout Routen ab — die alte Bedingung zeigte ihm also ausgerechnet
      // dann die Abgelaufen-Meldung. Umgekehrt erklaert sich der Verlust
      // jetzt auch dann, wenn der Nutzer direkt auf dem Home stand: er wird
      // ohne sein Zutun ausgeloggt, und das ist der ganze Punkt der Meldung.
      if (!isLoggedIn && !gewollt) {
        showAppSnack(
          context,
          'Deine Sitzung ist abgelaufen. Bitte melde dich erneut an.',
          icon: Icons.lock_clock_rounded,
          duration: kSnackError,
        );
      }
    }

    setState(() {
      _user = user;
      if (wasLoggedOut && isLoggedIn) {
        _freshLogin = true;
      } else if (!isLoggedIn) {
        _freshLogin = false;
      }
    });
  }

  /// Raeumt alles ab, was ueber der Root-Route liegt.
  ///
  /// `Navigator.maybeOf(context)` trifft hier den RICHTIGEN Navigator: die
  /// MaterialApp baut `home` in die Default-Route ihres eigenen Navigators,
  /// dieser State liegt also IM Navigator-Subtree und nicht darueber. Ein
  /// `GlobalKey<NavigatorState>` an der MaterialApp waere unnoetig (und
  /// eatova_app.dart muesste dafuer angefasst werden).
  ///
  /// `route.isFirst` statt `ModalRoute.withName('/')`: greift auch bei
  /// namenlosen Routen. Dialoge und Bottom Sheets sind selbst Routen und
  /// werden hier regulaer gepoppt â€” ihre Futures schliessen mit `null` ab, es
  /// bleibt kein halber Zustand stehen.
  void _popToRootRoute() {
    Navigator.maybeOf(context)?.popUntil((route) => route.isFirst);
  }

  @override
  void didUpdateWidget(covariant AuthGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authRepository == widget.authRepository) return;
    _subscription?.cancel();
    _user = widget.authRepository.currentUser;
    // Auch ein Repository-Tausch ist ein potenzieller Identitaetswechsel.
    unawaited(RecipeImageStore.instance.setActiveUser(_user?.id));
    _freshLogin = false;
    _subscription = widget.authRepository.authStateChanges
        .listen(_onAuthEvent, onError: _onAuthStreamError);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = _user;
    if (user == null) {
      return AuthScreen(authRepository: widget.authRepository);
    }
    return widget.builder(context, user, _freshLogin);
  }
}
