// Review 2026-10-19: the import reads TikTok links or pasted text, nothing
// else. A website link alone gets a clear local message before any request,
// and the text stays in the field to complete; pasted recipe text next to
// such a link is still sent.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/recipe_import_result.dart';
import 'package:eatova/src/screens/recipes/recipe_import_sheet.dart';
import 'package:eatova/src/services/recipe_import_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/widgets/design/design.dart';

import '../support/harness.dart';

const _chefkoch = 'https://www.chefkoch.de/rezepte/123/spaghetti.html';
const _tiktok = 'https://www.tiktok.com/@cook/video/1234567890123';

class _Service implements RecipeImportService {
  final List<String> inputs = [];

  @override
  Future<RecipeImportResult> extract(String text, {required String locale}) {
    inputs.add(text);
    return Future.value(
      const RecipeImportResult(status: RecipeImportStatus.needsText),
    );
  }
}

Future<void> _open(
  WidgetTester tester,
  _Service service, {
  String initialText = '',
  Locale locale = const Locale('de'),
}) async {
  await pumpLocalized(
    tester,
    Builder(
      builder: (context) => TextButton(
        onPressed: () => showRecipeImportSheet(
          context: context,
          service: service,
          onSave: (_) async => SyncDelivery.delivered,
          initialText: initialText,
          sessionIsCurrent: () => true,
        ),
        child: const Text('Open import'),
      ),
    ),
    surfaceSize: const Size(390, 844),
    locale: locale,
  );
  await tester.tap(find.text('Open import'));
  await tester.pumpAndSettle();
}

Finder get _notice =>
    find.byKey(const ValueKey('recipe-import-link-unsupported'));

PrimaryActionButton _analyze(WidgetTester tester) => tester.widget(
  find.byKey(const ValueKey('recipe-import-analyze')),
);

String _field(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('recipe-import-input')))
    .controller!
    .text;

void main() {
  group('recipeImportOnlyUnsupportedLinks', () {
    test('ein Website-Link allein oder mit Seitentitel', () {
      expect(recipeImportOnlyUnsupportedLinks(_chefkoch), isTrue);
      expect(
        recipeImportOnlyUnsupportedLinks('Spaghetti Carbonara | Chefkoch\n$_chefkoch'),
        isTrue,
      );
      expect(
        recipeImportOnlyUnsupportedLinks('Schau mal: $_chefkoch.'),
        isTrue,
      );
    });

    test('TikTok, reiner Text und Rezepttext neben einem Link gehen durch', () {
      expect(recipeImportOnlyUnsupportedLinks(_tiktok), isFalse);
      expect(
        recipeImportOnlyUnsupportedLinks('https://vm.tiktok.com/ZMabc123/'),
        isFalse,
      );
      expect(recipeImportOnlyUnsupportedLinks('200 g Reis\n1 Ei'), isFalse);
      expect(
        recipeImportOnlyUnsupportedLinks(
          '$_chefkoch\nZutaten:\n200 g Spaghetti\n2 Eier\nZubereitung: kochen.',
        ),
        isFalse,
      );
      // A TikTok link wins over another link: the server decides.
      expect(recipeImportOnlyUnsupportedLinks('$_tiktok $_chefkoch'), isFalse);
      expect(recipeImportOnlyUnsupportedLinks(''), isFalse);
    });
  });

  testWidgets('ein Website-Link: Meldung vor jeder Anfrage, der Text bleibt', (
    tester,
  ) async {
    final service = _Service();
    await _open(tester, service);
    await tester.enterText(
      find.byKey(const ValueKey('recipe-import-input')),
      _chefkoch,
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('recipe-import-analyze')));
    await tester.pumpAndSettle();

    expect(service.inputs, isEmpty, reason: 'keine Anfrage für den Link');
    expect(_notice, findsOneWidget);
    expect(
      find.text(
        'Links gehen bisher nur von TikTok. Kopier den Rezepttext von der '
        'Seite und füg ihn hier ein.',
      ),
      findsOneWidget,
    );
    expect(_field(tester), _chefkoch);
    expect(_analyze(tester).onTap, isNull);

    // Pasted recipe text completes it: the button is back, the text goes.
    const recipe = '$_chefkoch\nZutaten:\n200 g Spaghetti\n2 Eier';
    await tester.enterText(
      find.byKey(const ValueKey('recipe-import-input')),
      recipe,
    );
    await tester.pump();
    expect(_notice, findsNothing);
    expect(_analyze(tester).onTap, isNotNull);
    await tester.tap(find.byKey(const ValueKey('recipe-import-analyze')));
    await tester.pumpAndSettle();
    expect(service.inputs, [recipe]);
  });

  testWidgets('ein geteilter Website-Link startet keinen Import', (
    tester,
  ) async {
    final service = _Service();
    await _open(
      tester,
      service,
      initialText: 'Spaghetti | Chefkoch $_chefkoch',
      locale: const Locale('en'),
    );
    expect(service.inputs, isEmpty);
    expect(
      find.text(
        'Links only work from TikTok so far. Copy the recipe text from the '
        'page and paste it here.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('ein TikTok-Link geht wie bisher an den Import', (tester) async {
    final service = _Service();
    await _open(tester, service, initialText: _tiktok);
    expect(service.inputs, [_tiktok]);
    expect(_notice, findsNothing);
  });
}
