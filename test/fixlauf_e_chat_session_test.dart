import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/chat_session.dart';

// Fix run 2026-08-27, package E — F5-09 / F9-04: the model no longer invents a
// German title; placeholders are recognised and the display localizes them.

Map<String, dynamic> _row({Object? title}) => <String, dynamic>{
      'id': 's1',
      'title': title,
      'created_at': '2026-08-27T08:00:00Z',
      'last_message_at': '2026-08-27T09:00:00Z',
      'message_count': 0,
    };

void main() {
  test('fromRow ohne Titel liefert leer, nicht „Neue Unterhaltung"', () {
    expect(ChatSession.fromRow(_row()).title, '');
    expect(ChatSession.fromRow(_row(title: '   ')).title, '');
  });

  test('bekannte Platzhalter gelten als Default-Titel', () {
    for (final titel in <String>[
      '',
      'Neue Unterhaltung',
      'New conversation',
      'Allgemein',
      '  Neue Unterhaltung  ',
    ]) {
      expect(
        ChatSession.fromRow(_row(title: titel)).isDefaultTitle,
        isTrue,
        reason: '„$titel" ist ein gespeicherter Platzhalter',
      );
    }
  });

  test('echte Titel bleiben echte Titel', () {
    final s = ChatSession.fromRow(_row(title: 'Protein am Abend'));
    expect(s.title, 'Protein am Abend');
    expect(s.isDefaultTitle, isFalse);
  });
}
