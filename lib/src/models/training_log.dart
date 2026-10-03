import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The identity form of an exercise name: trimmed, inner whitespace collapsed
/// to one space, lowercase.
String normalizeExerciseName(String name) =>
    name.trim().replaceAll(_whitespace, ' ').toLowerCase();

final RegExp _whitespace = RegExp(r'\s+');

/// Exercise ID of a logged workout: 'n_' plus the first 32 hex chars of the
/// SHA-256 of the normalized name; the k-th repeat (k > 1) appends '_k'.
String trainingLogExerciseId(String name, int occurrence) {
  final digest = sha256
      .convert(utf8.encode(normalizeExerciseName(name)))
      .toString()
      .substring(0, 32);
  return occurrence > 1 ? 'n_${digest}_$occurrence' : 'n_$digest';
}
