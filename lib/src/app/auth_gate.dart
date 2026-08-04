import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../screens/auth_screen.dart';

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
    _subscription = widget.authRepository.authStateChanges.listen(_onAuthEvent);
  }

  void _onAuthEvent(EatovaUser? user) {
    if (!mounted) return;
    final wasLoggedOut = _user == null;
    final isLoggedIn = user != null;
    setState(() {
      _user = user;
      if (wasLoggedOut && isLoggedIn) {
        _freshLogin = true;
      } else if (!isLoggedIn) {
        _freshLogin = false;
      }
    });
  }

  @override
  void didUpdateWidget(covariant AuthGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authRepository == widget.authRepository) return;
    _subscription?.cancel();
    _user = widget.authRepository.currentUser;
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
