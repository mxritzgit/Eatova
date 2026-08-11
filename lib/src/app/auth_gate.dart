import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../screens/auth_screen.dart';
import '../services/recipe_image_store.dart';
import '../widgets/common/app_snack.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.authRepository,
    required this.builder,
  });

  final AuthRepository authRepository;

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
    _subscription = widget.authRepository.authStateChanges.listen(_onAuthEvent);
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
    if (!mounted) return;
    final previous = _user;
    final wasLoggedOut = previous == null;
    final isLoggedIn = user != null;

    // D8: AuthGate ist der Inhalt von MaterialApp.home, also der Root-Route.
    // Ein Auth-Wechsel tauschte bisher NUR diesen Inhalt â€” alles was der
    // Nutzer darueber gepusht hat (Profil, Trends, ein Dialog, ein Bottom
    // Sheet) blieb sichtbar und voll bedienbar und zeigte Daten einer Session,
    // die es nicht mehr gibt. Beim externen Session-Verlust (Passwortaenderung
    // auf einem anderen Geraet, serverseitiger Widerruf) also den
    // Navigator-Stack mit abraeumen.
    //
    // NUR beim echten Identitaetswechsel: ein Token-Refresh liefert denselben
    // Nutzer erneut und darf die offene Ansicht nicht wegraeumen.
    final identityChanged =
        !wasLoggedOut && (user == null || user.id != previous.id);
    if (identityChanged) {
      final removedRoutes = _popToRootRoute();
      // Wortlos auf dem Login zu landen, waehrend man gerade sein Profil
      // ansah, ist verwirrend â€” der Grund gehoert dazu. Der Hinweis haengt
      // hier und nicht im AuthScreen, weil nur der Gate den Unterschied
      // zwischen â€žabgemeldet" und â€žSitzung verloren" kennt; die Snackbar
      // laeuft ueber den ScaffoldMessenger der MaterialApp und wird vom
      // Scaffold des AuthScreens gezeigt, sobald der gebaut ist.
      //
      // [removedRoutes] ist zugleich die Abgrenzung zur gewollten
      // In-App-Abmeldung: die poppt selbst, BEVOR sie signOut ruft
      // (profile_screen.dart:137), steht hier also schon auf der Root-Route.
      // â€žDeine Sitzung ist abgelaufen" nach einem bewussten Logout waere
      // schlicht falsch. Und wo nichts weggeraeumt wurde, gibt es auch nichts
      // zu erklaeren â€” der Nutzer sieht denselben Login wie nach jedem Logout.
      if (!isLoggedIn && removedRoutes) {
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

  /// Raeumt alles ab, was ueber der Root-Route liegt, und meldet, ob dabei
  /// ueberhaupt etwas wegfiel.
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
  bool _popToRootRoute() {
    final navigator = Navigator.maybeOf(context);
    if (navigator == null) return false;
    var removed = false;
    navigator.popUntil((route) {
      if (route.isFirst) return true;
      removed = true;
      return false;
    });
    return removed;
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
    _subscription = widget.authRepository.authStateChanges.listen(_onAuthEvent);
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
