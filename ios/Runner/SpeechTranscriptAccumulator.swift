import Foundation

/// Joins the hypotheses of one SFSpeechRecognizer task into one transcript.
///
/// The recognizer reports the best hypothesis of the current utterance. After
/// a pause some iOS versions restart it with only the new words and never mark
/// the old one final (Apple forum threads 731761, 762952), so overwriting the
/// transcript with each result kept only the last phrase.
///
/// A new utterance starts after an end signal (`isFinal` or a non-nil
/// `speechRecognitionMetadata`), when the first segment starts clearly later
/// in the audio, or when the segment count collapses. Text is compared case-
/// and punctuation-folded, so a formatting revision never duplicates words.
/// Pure value type without Speech types so XCTest can replay traces.
struct SpeechTranscriptAccumulator {
  /// Forward jump of the first segment (seconds) that marks a new utterance.
  /// Revisions move it by a fraction of that; a restart follows a pause.
  static let restartGap: TimeInterval = 1.0

  private struct Utterance {
    let text: String
    let words: [String]
    let start: TimeInterval?
    let segmentCount: Int
  }

  private var committed: [Utterance] = []
  private var current: Utterance?

  /// Everything recognised so far, including the open utterance.
  var text: String {
    (committed + (current.map { [$0] } ?? [])).map { $0.text }.joined(separator: " ")
  }

  /// Feeds one recognizer callback. A `firstSegmentStart` of 0 counts as
  /// unknown, since results without timing information report 0.
  mutating func apply(text raw: String, firstSegmentStart: TimeInterval?, segmentCount: Int, utteranceEnded: Bool) {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let words = Self.foldedWords(text)
    guard !words.isEmpty else {
      if utteranceEnded { commitCurrent() }
      return
    }
    let next = Utterance(
      text: text,
      words: words,
      start: (firstSegmentStart ?? 0) > 0 ? firstSegmentStart : nil,
      segmentCount: segmentCount
    )
    if let open = current {
      if !Self.continues(open, with: next, afterEnd: false) { committed.append(open) }
    } else if let last = committed.last, Self.continues(last, with: next, afterEnd: true) {
      // A late final or a cumulative hypothesis of the utterance that just ended.
      committed.removeLast()
    }
    current = next
    if utteranceEnded { commitCurrent() }
  }

  private mutating func commitCurrent() {
    if let open = current { committed.append(open) }
    current = nil
  }

  /// Whether `next` is a later hypothesis of `previous` rather than a new utterance.
  private static func continues(_ previous: Utterance, with next: Utterance, afterEnd: Bool) -> Bool {
    // Growth, or the same words with other case or punctuation.
    if next.words.starts(with: previous.words) { return true }
    if let before = previous.start, let after = next.start, after - before >= restartGap { return false }
    // The forum trace collapses from 114 segments to 1; revisions never halve.
    if next.segmentCount * 2 < previous.segmentCount, previous.segmentCount - next.segmentCount >= 3 {
      return false
    }
    // Inside an utterance a reworded hypothesis is a revision. After an end
    // signal only a hypothesis at least as long that keeps most words in place
    // continues it (a recognizer that keeps the whole task in one hypothesis).
    guard afterEnd else { return true }
    let kept = zip(previous.words, next.words).filter { $0.0 == $0.1 }.count
    return next.segmentCount >= previous.segmentCount && kept * 2 >= previous.words.count
  }

  private static func foldedWords(_ text: String) -> [String] {
    text.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
  }
}
