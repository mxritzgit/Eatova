/// The filter subset used by the diary fakes. Unsupported syntax fails loudly.
bool matchesPostgrestFilters(Map<String, dynamic> row, Uri uri) {
  for (final entry in uri.queryParametersAll.entries) {
    if (const {'select', 'order', 'limit', 'offset'}.contains(entry.key)) {
      continue;
    }
    for (final filter in entry.value) {
      if (!_matches(row, '${entry.key}.$filter')) return false;
    }
  }
  return true;
}

bool _matches(Map<String, dynamic> row, String expression) {
  for (final operator in ['or', 'and']) {
    final prefix = '$operator.';
    final nestedPrefix = '$operator(';
    if (expression.startsWith(prefix) || expression.startsWith(nestedPrefix)) {
      final body = expression.startsWith(prefix)
          ? expression.substring(prefix.length)
          : expression.substring(operator.length);
      if (!body.startsWith('(') || !body.endsWith(')')) {
        throw FormatException('Malformed filter group: $expression');
      }
      final matches = _splitGroup(
        body.substring(1, body.length - 1),
      ).map((part) => _matches(row, part)).toList();
      return operator == 'or'
          ? matches.any((value) => value)
          : matches.every((value) => value);
    }
  }
  final match = RegExp(
    r'^([a-z_]+)\.(eq|gt|gte|lt|is)\.(.+)$',
  ).firstMatch(expression);
  if (match == null) throw FormatException('Unsupported filter: $expression');
  final column = match[1]!;
  if (!row.containsKey(column)) {
    throw StateError('Missing column in query fixture: $column');
  }
  final value = row[column];
  final expected = match[3]!;
  return switch (match[2]) {
    'eq' => value != null && value.toString() == expected,
    'gt' when column == 'id' =>
      value != null && value.toString().compareTo(expected) > 0,
    'is' when expected == 'null' => value == null,
    'gte' =>
      value != null &&
          !DateTime.parse(value as String).isBefore(DateTime.parse(expected)),
    'lt' =>
      value != null &&
          DateTime.parse(value as String).isBefore(DateTime.parse(expected)),
    _ => throw FormatException('Unsupported filter: $expression'),
  };
}

List<String> _splitGroup(String body) {
  final parts = <String>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i < body.length; i++) {
    if (body[i] == '(') depth++;
    if (body[i] == ')') depth--;
    if (depth < 0) throw FormatException('Unbalanced filter: $body');
    if (body[i] == ',' && depth == 0) {
      parts.add(body.substring(start, i));
      start = i + 1;
    }
  }
  if (depth != 0) throw FormatException('Unbalanced filter: $body');
  parts.add(body.substring(start));
  return parts;
}
