import 'package:flutter/material.dart';

/// Shared input behavior for pages, dialogs and modal routes.
class AppInteractions extends StatelessWidget {
  const AppInteractions({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        EditableTextTapUpOutsideIntent:
            CallbackAction<EditableTextTapUpOutsideIntent>(
              onInvoke: (intent) {
                // Wait until release so a keyboard-dependent layout cannot move
                // an action away from the finger before its tap completes.
                if (intent.focusNode.hasFocus) intent.focusNode.unfocus();
                return null;
              },
            ),
      },
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        ),
        child: child,
      ),
    );
  }
}
