import 'package:shared_preferences/shared_preferences.dart';

/// Language the Coach dictation listens in (spec D5).
///
/// Apple's recognizers take one locale per session, so a German speaker with
/// an English UI needs a visible switch; mixed speech stays out of reach
/// on-device.
enum DictationLanguage {
  de('de_DE'),
  en('en_US');

  const DictationLanguage(this.localeId);

  /// Locale id for the `eatova/speech` channel.
  final String localeId;

  DictationLanguage get other => this == de ? en : de;

  /// Default until the user picks one: the app language.
  static DictationLanguage forAppLanguage(String languageCode) =>
      languageCode == 'en' ? en : de;
}

/// Per-device memory of the last chosen [DictationLanguage].
abstract class DictationLanguageStore {
  /// null: nothing chosen yet, or unreadable.
  Future<DictationLanguage?> load();

  Future<void> save(DictationLanguage language);
}

/// SharedPreferences, like the app language (`LocaleController`): a device
/// setting, not account data. Stores only `de`/`en`, never a transcript.
final class PrefsDictationLanguageStore implements DictationLanguageStore {
  const PrefsDictationLanguageStore();

  static const String storageKey = 'eatova.v1.dictation_language';

  @override
  Future<DictationLanguage?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return switch (prefs.getString(storageKey)) {
        'de' => DictationLanguage.de,
        'en' => DictationLanguage.en,
        _ => null,
      };
    } catch (_) {
      // Prefs unavailable: the app language applies.
      return null;
    }
  }

  @override
  Future<void> save(DictationLanguage language) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, language.name);
    } catch (_) {
      // Not persisted; the running session keeps the choice.
    }
  }
}
