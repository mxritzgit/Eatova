// Describe sheet dictation: iOS streams partials from the in-app recognizer,
// Android answers once from the system dialog (which pauses the app), other
// platforms have no mic. Failures, ends, the DE/EN pill, the screen hold and
// the lifecycle.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/dictation_language.dart';
import 'package:eatova/src/services/speech_input.dart';

import 'describe_harness.dart';

Future<void> _tapMic(WidgetTester tester) async {
  await tester.tap(describeMic);
  await tester.pump();
}

Future<void> _lifecycle(
  WidgetTester tester,
  List<AppLifecycleState> states,
) async {
  for (final state in states) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pump();
}

const _toBackground = [
  AppLifecycleState.inactive,
  AppLifecycleState.hidden,
  AppLifecycleState.paused,
];

const _toForeground = [
  AppLifecycleState.hidden,
  AppLifecycleState.inactive,
  AppLifecycleState.resumed,
];

void main() {
  testWidgets('iOS: partials stream in, stop then submit uses the final text', (
    tester,
  ) async {
    await onPlatform(TargetPlatform.iOS, () async {
      final semantics = tester.ensureSemantics();
      final h = await openDescribe(tester);
      final l10n = l10nOf(tester);
      expect(tester.getSemantics(describeMic).label, l10n.foodDescribeMicStart);

      await _tapMic(tester);
      final call = h.speech.listens.single;
      expect(call.localeId, 'de_DE');
      expect(call.vocabulary, SpeechVocabulary.food);
      expect(call.maxChars, 500);
      expect(h.awake.held, isTrue);
      expect(tester.getSemantics(describeMic).label, l10n.foodDescribeMicStop);

      h.speech.partial('Nutella auf');
      await tester.pump();
      expect(fieldText(tester), 'Nutella auf');
      h.speech.partial('Nutella auf einer Scheibe Toast');
      await tester.pump();
      expect(fieldText(tester), 'Nutella auf einer Scheibe Toast');
      expect(enabled(tester, describeSubmit), isTrue);

      h.speech.finalText = 'Nutella auf einer Scheibe Toast von Lidl';
      await tester.tap(describeSubmit);
      await tester.pumpAndSettle();

      expect(h.speech.stops, 1);
      expect(h.speech.cancels, 0);
      expect(h.describer.calls, hasLength(1));
      expect(
        h.describer.calls.single.text,
        'Nutella auf einer Scheibe Toast von Lidl',
      );
      expect(h.awake.held, isFalse);
      expect(key('meal-describe-line-0'), findsOneWidget);
      semantics.dispose();
    });
  });

  testWidgets('iOS: a second mic tap stops; dictation follows typed text', (
    tester,
  ) async {
    await onPlatform(TargetPlatform.iOS, () async {
      final h = await openDescribe(tester);
      await tester.enterText(describeInput, 'Zum Frühstück');
      await tester.pump();
      await _tapMic(tester);
      // The room left after the typed text and one space.
      expect(h.speech.listens.single.maxChars, 500 - 'Zum Frühstück '.length);
      h.speech.partial('zwei Eier');
      await tester.pump();
      expect(fieldText(tester), 'Zum Frühstück zwei Eier');

      await _tapMic(tester);
      await tester.pump();
      expect(h.speech.stops, 1);
      expect(fieldText(tester), 'Zum Frühstück zwei Eier');
      expect(h.describer.calls, isEmpty, reason: 'stop only fills the field');
      expect(h.awake.held, isFalse);
    });
  });

  testWidgets('iOS: a final text over the cap is clamped to 500', (
    tester,
  ) async {
    await onPlatform(TargetPlatform.iOS, () async {
      final h = await openDescribe(tester);
      await _tapMic(tester);
      h.speech.finish('Brot ' * 110, end: SpeechEnd.length);
      await tester.pump();
      expect(fieldText(tester).length, lessThanOrEqualTo(500));
      expect(fieldText(tester), startsWith('Brot Brot'));
      expect(
        find.text(l10nOf(tester).foodDescribeSpeechLength),
        findsOneWidget,
      );
      expect(enabled(tester, describeSubmit), isTrue);
    });
  });

  testWidgets('iOS: a recognizer that never answers a stop is ended', (
    tester,
  ) async {
    await onPlatform(TargetPlatform.iOS, () async {
      final semantics = tester.ensureSemantics();
      final h = await openDescribe(tester);
      h.speech.stopAnswers = false;
      await _tapMic(tester);
      h.speech.partial('Apfel');
      await tester.pump();
      await _tapMic(tester);
      await tester.pump(const Duration(seconds: 4));
      expect(h.speech.cancels, 1);
      expect(fieldText(tester), 'Apfel');
      expect(h.awake.held, isFalse);
      expect(
        tester.getSemantics(describeMic).label,
        l10nOf(tester).foodDescribeMicStart,
      );
      semantics.dispose();
    });
  });

  testWidgets('Android: no partials, the text arrives at the end', (
    tester,
  ) async {
    await onPlatform(TargetPlatform.android, () async {
      final h = await openDescribe(tester);
      await _tapMic(tester);
      expect(h.speech.listens, hasLength(1));
      expect(fieldText(tester), isEmpty);
      // The listening state shows behind the system dialog.
      expect(find.text(l10nOf(tester).foodDescribeMicListening), findsWidgets);
      expect(enabled(tester, describeSubmit), isFalse);

      h.speech.finish('Zwei Eier mit Speck');
      await tester.pump();
      expect(fieldText(tester), 'Zwei Eier mit Speck');
      expect(h.awake.held, isFalse);
      expect(enabled(tester, describeSubmit), isTrue);
    });
  });

  testWidgets(
    'Android: the dialog pausing the app does not end the dictation',
    (tester) async {
      await onPlatform(TargetPlatform.android, () async {
        final h = await openDescribe(tester);
        await _tapMic(tester);
        await _lifecycle(tester, _toBackground);
        expect(h.speech.cancels, 0);
        expect(h.speech.isListening, isTrue);

        await _lifecycle(tester, _toForeground);
        h.speech.finish('Haferflocken mit Milch');
        await tester.pump();
        expect(fieldText(tester), 'Haferflocken mit Milch');
        expect(h.speech.cancels, 0);
      });
    },
  );

  testWidgets('Android: taps that land before the dialog never end it', (
    tester,
  ) async {
    await onPlatform(TargetPlatform.android, () async {
      final h = await openDescribe(tester);
      h.speech.systemDialog = true;
      await tester.enterText(describeInput, 'Kaffee');
      await tester.pump();
      await tester.ensureVisible(describeSubmit);
      await tester.pumpAndSettle();

      await _tapMic(tester);
      // The dialog needs a moment to cover the sheet; taps meanwhile still
      // reach it: the pill, the mic again, the field, Send.
      await tester.tap(key('meal-describe-language'));
      await tester.pump();
      await _tapMic(tester);
      await tester.tap(describeInput);
      await tester.pump();
      await tester.tap(describeSubmit);
      await tester.pump(const Duration(seconds: 5));
      expect(h.speech.listens, hasLength(1));
      expect(h.speech.isListening, isTrue, reason: 'the dialog still runs');
      expect(enabled(tester, describeSubmit), isFalse);

      h.speech.finish('mit Milch');
      await tester.pump();
      await tester.pump();
      expect(fieldText(tester), 'Kaffee mit Milch');
      expect(h.describer.calls, isEmpty, reason: 'read before it is sent');
      expect(key('meal-describe-voice-notice'), findsNothing);
      expect(h.awake.held, isFalse);
      expect(enabled(tester, describeSubmit), isTrue);
    });
  });

  testWidgets('Android: a dismissed dialog is quiet, one that heard nothing '
      'says so', (tester) async {
    await onPlatform(TargetPlatform.android, () async {
      final h = await openDescribe(tester);
      h.speech.systemDialog = true;
      final notice = key('meal-describe-voice-notice');

      await _tapMic(tester);
      h.speech.finish(null, end: SpeechEnd.dismissed);
      await tester.pump();
      await tester.pump();
      expect(notice, findsNothing);
      expect(h.awake.held, isFalse);

      await _tapMic(tester);
      h.speech.finish(null);
      await tester.pump();
      await tester.pump();
      expect(notice, findsOneWidget);
      expect(find.text(l10nOf(tester).foodDescribeSpeechEmpty), findsOneWidget);
    });
  });

  testWidgets('iOS: a close attempt ends the recording before it asks', (
    tester,
  ) async {
    await onPlatform(TargetPlatform.iOS, () async {
      final h = await openDescribe(tester);
      final l10n = l10nOf(tester);
      await _tapMic(tester);
      h.speech.partial('Zwei Eier');
      await tester.pump();

      await tester.tap(key('meal-describe-close'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(key('describe-discard-dialog'), findsOneWidget);
      expect(h.speech.cancels, 1, reason: 'no live mic behind the dialog');
      expect(h.awake.held, isFalse);
      h.speech.partial('Zwei Eier mit Speck');
      await tester.pump();

      await tester.tap(key('describe-discard-cancel'));
      await tester.pumpAndSettle();
      expect(h.closed, isFalse);
      expect(fieldText(tester), 'Zwei Eier');
      expect(find.text(l10n.foodDescribeMicTitle), findsOneWidget);
    });
  });

  testWidgets('iOS: going to the background ends the recording, text kept', (
    tester,
  ) async {
    await onPlatform(TargetPlatform.iOS, () async {
      final h = await openDescribe(tester);
      await _tapMic(tester);
      h.speech.partial('Müsli mit');
      await tester.pump();
      // A permission prompt makes the app inactive only: keep listening.
      await _lifecycle(tester, const [AppLifecycleState.inactive]);
      expect(h.speech.cancels, 0);
      await _lifecycle(tester, const [
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);
      expect(h.speech.cancels, 1);
      expect(fieldText(tester), 'Müsli mit');
      expect(h.awake.held, isFalse);
      await _lifecycle(tester, _toForeground);
    });
  });

  for (final platform in const [
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  ]) {
    testWidgets('${platform.name}: no mic, typing still works', (tester) async {
      await onPlatform(platform, () async {
        final h = await openDescribe(tester);
        expect(describeMic, findsNothing);
        expect(key('meal-describe-language'), findsNothing);
        await describe(tester, 'Spaghetti Bolognese');
        expect(h.describer.calls.single.text, 'Spaghetti Bolognese');
      });
    });
  }

  for (final failure in SpeechFailure.values) {
    testWidgets('a ${failure.name} failure is named, mic released', (
      tester,
    ) async {
      final h = await openDescribe(tester);
      final l10n = l10nOf(tester);
      h.speech.failWith = SpeechInputException(failure);
      await _tapMic(tester);
      await tester.pump();
      final message = switch (failure) {
        SpeechFailure.permissionDenied =>
          l10n.foodDescribeSpeechPermissionDenied,
        SpeechFailure.unavailable => l10n.foodDescribeSpeechUnavailable,
        SpeechFailure.busy => l10n.foodDescribeSpeechBusy,
        SpeechFailure.failed => l10n.foodDescribeSpeechFailed,
      };
      expect(find.text(message), findsOneWidget);
      expect(h.awake.held, isFalse);
      expect(fieldText(tester), isEmpty);
      // Typing answers the hint.
      await tester.enterText(describeInput, 'Toast');
      await tester.pump();
      expect(find.text(message), findsNothing);
    });
  }

  testWidgets('nothing recognized and the minute limit get calm hints', (
    tester,
  ) async {
    final h = await openDescribe(tester);
    final l10n = l10nOf(tester);
    await _tapMic(tester);
    h.speech.finish(null);
    await tester.pump();
    expect(find.text(l10n.foodDescribeSpeechEmpty), findsOneWidget);

    await _tapMic(tester);
    h.speech.finish('Ein Apfel', end: SpeechEnd.limit);
    await tester.pump();
    expect(find.text(l10n.foodDescribeSpeechLimit), findsOneWidget);
    expect(fieldText(tester), 'Ein Apfel');
  });

  testWidgets('the pill picks the language and restarts a running recording', (
    tester,
  ) async {
    await onPlatform(TargetPlatform.iOS, () async {
      final semantics = tester.ensureSemantics();
      final h = await openDescribe(tester);
      final pill = key('meal-describe-language');
      expect(tester.getSemantics(pill).label, 'Diktiersprache: Deutsch');

      await tester.tap(pill);
      await tester.pump();
      expect(h.languages.value, DictationLanguage.en);
      expect(tester.getSemantics(pill).label, 'Diktiersprache: Englisch');
      await tester.tap(pill);
      await tester.pump();
      expect(h.languages.value, DictationLanguage.de);

      await tester.enterText(describeInput, 'Kaffee');
      await tester.pump();
      await _tapMic(tester);
      h.speech.partial('with oat milk');
      await tester.pump();
      await tester.tap(pill);
      await tester.pump();
      expect(h.speech.cancels, 1);
      expect(h.speech.listens, hasLength(2));
      expect(h.speech.listens.last.localeId, 'en_US');
      expect(h.languages.value, DictationLanguage.en);
      expect(fieldText(tester), 'Kaffee', reason: 'the restart drops the take');

      h.speech.partial('with oat milk');
      await tester.pump();
      expect(fieldText(tester), 'Kaffee with oat milk');
      semantics.dispose();
    });
  });

  testWidgets('a stored language applies to the next recording', (
    tester,
  ) async {
    final host = DescribeHost();
    host.languages.value = DictationLanguage.en;
    await openDescribe(tester, host: host);
    await _tapMic(tester);
    expect(host.speech.listens.single.localeId, 'en_US');
  });

  testWidgets('closing while listening cancels and releases the screen', (
    tester,
  ) async {
    final h = await openDescribe(tester);
    await _tapMic(tester);
    expect(h.awake.held, isTrue);
    await tester.tap(key('meal-describe-close'));
    await tester.pumpAndSettle();
    expect(h.closed, isTrue);
    expect(h.speech.cancels, 1);
    expect(h.awake.held, isFalse);
  });
}
