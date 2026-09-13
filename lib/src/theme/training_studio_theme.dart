import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'app_tokens.dart';

/// Keep native bars readable when entering the dark studio from light mode.
class TrainingStudioChrome extends StatelessWidget {
  const TrainingStudioChrome({
    super.key,
    required this.active,
    required this.child,
  });

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = active || Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
          .copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: active ? AppTokens.dark.bg : context.t.bg,
          ),
      child: child,
    );
  }
}

/// Nachtstudio is a dark training surface in either app appearance.
class TrainingStudioTheme extends StatelessWidget {
  const TrainingStudioTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Theme(
    data: buildEatovaTheme(
      Brightness.dark,
    ).copyWith(platform: Theme.of(context).platform),
    child: child,
  );
}
