import 'dart:typed_data';

enum MealPortionHint {
  small('klein', '~30% weniger als Standardportion'),
  normal('normal', 'Standardportion'),
  large('groß', '~50% mehr als Standardportion'),
  extraLarge('sehr groß', '~doppelte Standardportion');

  const MealPortionHint(this.label, this.guidance);

  final String label;
  final String guidance;
}

/// Cooperative cancel handle for one photo analysis (Review 2026-08-27,
/// F4-02): the result sheet cancels on dispose, the analyzer closes its
/// [HttpClient]. This only frees the client (socket, wait time): the server
/// consumes the rate-limit slot BEFORE the provider call and the provider
/// request runs to its own timeout regardless.
///
/// One handle outlives retries — every attempt registers its own callback and
/// unregisters in its `finally`. [cancel] is idempotent.
class MealAnalysisCancellation {
  bool _cancelled = false;
  final List<void Function()> _callbacks = <void Function()>[];

  bool get isCancelled => _cancelled;

  /// Runs [callback] on [cancel] — at once if already cancelled. Returns the
  /// unregister function for the attempt's `finally`.
  void Function() register(void Function() callback) {
    if (_cancelled) {
      callback();
      return () {};
    }
    _callbacks.add(callback);
    return () => _callbacks.remove(callback);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final pending = List<void Function()>.of(_callbacks);
    _callbacks.clear();
    for (final callback in pending) {
      callback();
    }
  }
}

class MealAnalysisRequest {
  const MealAnalysisRequest({
    required this.imageId,
    this.imageBytes,
    this.portionHint,
    this.freeTextHint,
    this.language = 'de',
    this.cancellation,
  });

  final String imageId;
  final Uint8List? imageBytes;
  final MealPortionHint? portionHint;
  final String? freeTextHint;

  /// App language at scan time (`'de'`/`'en'`), sent to the `analyze-meal`
  /// function so it names dishes in that language.
  ///
  /// Default `'de'` matches the server default, for construction sites without
  /// a locale (no `BuildContext` there). The actual caller sets the real
  /// language via [withLanguage] right before `MealAnalyzer.analyze()`.
  final String language;

  /// Optional cancel handle; the camera sheet attaches one so the result sheet
  /// can abort the in-flight request. Null = not cancellable.
  final MealAnalysisCancellation? cancellation;

  /// Copy with [language] replaced — see there.
  MealAnalysisRequest withLanguage(String language) => MealAnalysisRequest(
        imageId: imageId,
        imageBytes: imageBytes,
        portionHint: portionHint,
        freeTextHint: freeTextHint,
        language: language,
        cancellation: cancellation,
      );
}
