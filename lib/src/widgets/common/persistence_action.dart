import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../l10n/l10n.dart';
import '../design/sheets.dart';
import 'app_snack.dart';

typedef PersistValueChanged<T> = FutureOr<void> Function(T value);

/// An in-flight commit cannot be cancelled by closing its form. Prevent both
/// route pops and Material's drag-to-close path until the outcome is known.
class CommitDismissGuard extends StatelessWidget {
  const CommitDismissGuard({
    super.key,
    required this.pending,
    required this.child,
  });

  final bool pending;
  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: !pending,
    child: SheetDismissGuard(
      active: pending,
      onDismissAttempt: () {},
      child: ExcludeFocus(
        excluding: pending,
        child: AbsorbPointer(absorbing: pending, child: child),
      ),
    ),
  );
}

/// Success means the local commit completed, including its pending sync intent.
/// Callers retain their draft and suppress success feedback when it fails.
Future<bool> tryPersistChange(
  BuildContext context,
  FutureOr<void> Function() persist,
) async {
  try {
    await persist();
    return true;
  } catch (_) {
    if (context.mounted) {
      showAppSnack(
        context,
        context.l10n.commonLocalSaveFailed,
        tone: SnackTone.error,
        duration: kSnackError,
      );
    }
    return false;
  }
}
