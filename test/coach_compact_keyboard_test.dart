import 'dart:io';
import 'dart:typed_data';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'support/harness.dart';

class _KeyboardCoach extends CoachChatService {
  _KeyboardCoach(SupabaseClient client) : super(client, 'fixture-user');

  static _KeyboardCoach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((_) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _KeyboardCoach(client);
  }

  @override
  Future<List<ChatSession>> loadSessions() async => [
    ChatSession(
      id: 'fixture-session',
      title: 'Fixture',
      createdAt: DateTime(2026, 9, 8),
      lastMessageAt: DateTime(2026, 9, 8),
      messageCount: 0,
    ),
  ];

  @override
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async => [];

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async =>
      const ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5);
}

Future<void> _loadFonts() async {
  for (final family in ['Archivo', 'BricolageGrotesque']) {
    final loader = FontLoader(family);
    for (final file in Directory('assets/fonts').listSync().whereType<File>()) {
      if (file.uri.pathSegments.last.startsWith('$family-')) {
        loader.addFont(file.readAsBytes().then(ByteData.sublistView));
      }
    }
    await loader.load();
  }
}

void main() {
  setUpAll(_loadFonts);

  for (final locale in [const Locale('de'), const Locale('en')]) {
    testWidgets(
      'Both commands stay tappable above a keyboard in the real shell ($locale)',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 568);
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
        tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 20);
        addTearDown(tester.view.reset);
        await pumpLocalized(
          tester,
          Scaffold(
            body: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                child: CoachChatScreen(service: _KeyboardCoach.create()),
              ),
            ),
            bottomNavigationBar: AppNavBar(
              index: 4,
              onChanged: (_) {},
              items: const [
                AppNavItem(
                  icon: Icons.home_outlined,
                  activeIcon: Icons.home,
                  label: 'Heute',
                ),
                AppNavItem(
                  icon: Icons.restaurant,
                  activeIcon: Icons.restaurant,
                  label: 'Food',
                ),
                AppNavItem(
                  icon: Icons.menu_book,
                  activeIcon: Icons.menu_book,
                  label: 'Rezepte',
                ),
                AppNavItem(
                  icon: Icons.fitness_center,
                  activeIcon: Icons.fitness_center,
                  label: 'Training',
                ),
                AppNavItem(
                  icon: Icons.forum_outlined,
                  activeIcon: Icons.forum,
                  label: 'Coach',
                ),
              ],
            ),
          ),
          locale: locale,
          textScale: 2,
          safeArea: false,
          scaffold: false,
          settle: true,
        );
        expect(find.byKey(const ValueKey('coach-streak')), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('coach-input')), '/');
        tester.view.viewInsets = const FakeViewPadding(bottom: 220);
        await tester.pumpAndSettle();

        final menu = find.byKey(const ValueKey('coach-command-menu'));
        expect(tester.getSize(menu).height, greaterThanOrEqualTo(96));
        for (final command in ['recipe', 'plan']) {
          final item = find.byKey(ValueKey('coach-command-$command'));
          final bounds = tester.getRect(item);
          expect(bounds.height, greaterThanOrEqualTo(48));
          expect(tester.getRect(menu).contains(bounds.topCenter), isTrue);
          expect(
            tester
                .getRect(menu)
                .contains(bounds.bottomCenter - const Offset(0, 1)),
            isTrue,
          );
          expect(item.hitTestable(), findsOneWidget);
        }
        expect(
          find.byKey(const ValueKey('coach-info')).hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('coach-sessions-open')).hitTestable(),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('coach-command-plan')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('coach-input')))
              .controller!
              .text,
          '/plan ',
        );
        await tester.tap(find.byKey(const ValueKey('coach-send')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final feedback = find.byKey(const ValueKey('coach-feedback-scroll'));
        expect(feedback.hitTestable(), findsOneWidget);
        expect(
          find.text(tester.element(feedback).l10n.coachPlanEmptyHint),
          findsOneWidget,
        );
        final feedbackScroll = tester.state<ScrollableState>(
          find.descendant(of: feedback, matching: find.byType(Scrollable)),
        );
        expect(feedbackScroll.position.maxScrollExtent, greaterThan(0));
        await tester.drag(feedback, const Offset(0, -300));
        await tester.pumpAndSettle();
        expect(
          feedbackScroll.position.pixels,
          feedbackScroll.position.maxScrollExtent,
        );
        expect(
          find.byKey(const ValueKey('coach-input')).hitTestable(),
          findsOneWidget,
        );
        tester.view.viewInsets = FakeViewPadding.zero;
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('coach-streak')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
