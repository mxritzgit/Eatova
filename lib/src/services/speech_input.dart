// Dart side of the `eatova/speech` channel, shared by the Coach and the meal
// description. Contract: docs/MEAL-DESCRIBE.md (Speech).

import 'package:flutter/foundation.dart';

/// Why a recording ended, as far as the user needs a hint.
enum SpeechEnd {
  /// Stopped or cancelled by Dart, finished by the recognizer, or the system
  /// dialog returned.
  stopped,

  /// Apple's server path ended the task after about a minute.
  limit,

  /// The text reached the caller's [SpeechInput.listen] `maxChars`.
  length,
}

/// Words that bias recognition (iOS only; Android ignores it).
enum SpeechVocabulary { gym, food }

/// Typed failure; callers pick the localized message.
enum SpeechFailure { permissionDenied, unavailable, busy, failed }

class SpeechInputException implements Exception {
  const SpeechInputException(this.failure);
  final SpeechFailure failure;

  @override
  String toString() => 'SpeechInputException(${failure.name})';
}

class SpeechInput {
  const SpeechInput();

  /// Platforms with a native `eatova/speech` implementation.
  static bool supportedOn(TargetPlatform platform) =>
      throw UnimplementedError('SpeechInput.supportedOn');

  /// Whether partial transcripts stream while listening (iOS) or the text
  /// arrives only at the end (Android system dialog).
  static bool streamsPartialsOn(TargetPlatform platform) =>
      throw UnimplementedError('SpeechInput.streamsPartialsOn');

  /// Listens once. [token] must be unique per call; partials of an older
  /// call are dropped. Returns null when nothing was recognized or the user
  /// dismissed the recognizer. Throws [SpeechInputException].
  Future<String?> listen({
    required String localeId,
    required int token,
    SpeechVocabulary vocabulary = SpeechVocabulary.gym,
    int maxChars = 1000,
    ValueChanged<String>? onPartial,
    ValueChanged<SpeechEnd>? onEnd,
  }) => throw UnimplementedError('SpeechInput.listen');

  /// Graceful: the running [listen] completes with the final result.
  Future<void> stop() => throw UnimplementedError('SpeechInput.stop');

  /// Immediate: the running [listen] completes with what it has.
  Future<void> cancel() => throw UnimplementedError('SpeechInput.cancel');
}
