import XCTest
@testable import Runner

/// One recognizer callback: the best transcription and its segment metadata.
private struct Hypothesis {
  let text: String
  let start: TimeInterval?
  let segments: Int
  let ended: Bool

  /// `segments` defaults to the word count; `ended` stands for `isFinal` or
  /// a non-nil `speechRecognitionMetadata`.
  init(_ text: String, start: TimeInterval?, segments: Int? = nil, ended: Bool = false) {
    self.text = text
    self.start = start
    self.segments = segments ?? text.split(separator: " ").count
    self.ended = ended
  }
}

/// Turns recognizer callbacks into the transcript Dart receives.
protocol TranscriptStrategy {
  var text: String { get }
  mutating func apply(text: String, firstSegmentStart: TimeInterval?, segmentCount: Int, utteranceEnded: Bool)
}

extension SpeechTranscriptAccumulator: TranscriptStrategy {}

/// The plugin before this fix (AppDelegate.swift `lastTranscription =
/// bestTranscription.formattedString`): every callback replaced the transcript.
struct OverwriteAccumulator: TranscriptStrategy {
  private(set) var text = ""

  mutating func apply(text: String, firstSegmentStart: TimeInterval?, segmentCount: Int, utteranceEnded: Bool) {
    self.text = text
  }
}

private func transcript<Strategy: TranscriptStrategy>(
  _ strategy: Strategy,
  after hypotheses: [Hypothesis]
) -> String {
  var strategy = strategy
  for hypothesis in hypotheses {
    strategy.apply(
      text: hypothesis.text,
      firstSegmentStart: hypothesis.start,
      segmentCount: hypothesis.segments,
      utteranceEnded: hypothesis.ended
    )
  }
  return strategy.text
}

private func words(_ range: ClosedRange<Int>) -> [String] {
  range.map { "word\($0)" }
}

/// Apple forum threads 731761 and 762952: the hypothesis grows to 114
/// segments, is revised to 105, and after a pause restarts with one segment
/// of new text that starts later in the audio. Nothing is marked final.
private func forumResetTrace(start: (TimeInterval, TimeInterval)?) -> (hypotheses: [Hypothesis], expected: String) {
  let revised = (words(1...104) + ["merged"]).joined(separator: " ")
  let first = start?.0 ?? 0
  let second = start?.1 ?? 0
  let hypotheses = [
    Hypothesis(words(1...112).joined(separator: " "), start: first),
    Hypothesis(words(1...114).joined(separator: " "), start: first),
    Hypothesis(revised, start: first),
    Hypothesis("Then", start: second),
    Hypothesis("Then squats", start: second),
    Hypothesis("Then squats three sets", start: second),
  ]
  return (hypotheses, revised + " Then squats three sets")
}

final class SpeechTranscriptAccumulatorTests: XCTestCase {
  /// The strategy under test.
  private func subject() -> SpeechTranscriptAccumulator {
    SpeechTranscriptAccumulator()
  }

  private func assertTranscript(
    _ hypotheses: [Hypothesis],
    equals expected: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(transcript(subject(), after: hypotheses), expected, file: file, line: line)
  }

  func testOldOverwriteStrategyLosesEverythingBeforeThePause() {
    // Documents the reported bug: about a minute of dictation, only the last
    // words arrived.
    let trace = forumResetTrace(start: (0.4, 33.8))
    let old = transcript(OverwriteAccumulator(), after: trace.hypotheses)
    XCTAssertNotEqual(old, trace.expected)
    XCTAssertEqual(old, "Then squats three sets")
    XCTAssertEqual(transcript(SpeechTranscriptAccumulator(), after: trace.hypotheses), trace.expected)
  }

  func testForumResetTraceKeepsBothUtterances() {
    let trace = forumResetTrace(start: (0.4, 33.8))
    assertTranscript(trace.hypotheses, equals: trace.expected)
  }

  func testSegmentCollapseAloneMarksARestartWithoutTimestamps() {
    // Partial results may carry no timing (0); the collapse 105 -> 1 decides.
    let trace = forumResetTrace(start: nil)
    assertTranscript(trace.hypotheses, equals: trace.expected)
  }

  func testLaterFirstSegmentMarksARestartOfAShortUtterance() {
    assertTranscript([
      Hypothesis("Okay.", start: 0.5),
      Hypothesis("Today", start: 3.1),
      Hypothesis("Today I did", start: 3.1),
    ], equals: "Okay. Today I did")
  }

  func testOneMinuteWithPausesKeepsEveryUtteranceInOrder() {
    assertTranscript([
      Hypothesis("Heute", start: 0.6),
      Hypothesis("Heute Bankdrücken", start: 0.6),
      Hypothesis("Heute Bankdrücken drei Sätze", start: 0.6),
      Hypothesis("Mit 80", start: 9.2),
      Hypothesis("Mit 80 kg.", start: 9.2),
      Hypothesis("Dann", start: 21.4),
      Hypothesis("Dann Kniebeugen", start: 21.4),
      Hypothesis("Dann Kniebeugen 5 × 5.", start: 21.4),
      Hypothesis("Fertig", start: 48.0),
    ], equals: "Heute Bankdrücken drei Sätze Mit 80 kg. Dann Kniebeugen 5 × 5. Fertig")
  }

  func testPunctuationAndCapitalisationRevisionsDoNotDuplicate() {
    assertTranscript([
      Hypothesis("i did", start: 0.5),
      Hypothesis("i did 20 reps", start: 0.5),
      Hypothesis("I did 20 reps.", start: 0.62),
      Hypothesis("I did 20 reps.", start: 0.62, ended: true),
    ], equals: "I did 20 reps.")
  }

  func testSameWordsNeverDuplicateEvenWhenTimingShifts() {
    assertTranscript([
      Hypothesis("i did 20 reps", start: 0.5),
      Hypothesis("I did 20 reps.", start: 1.9, ended: true),
    ], equals: "I did 20 reps.")
  }

  func testUntimedPartialsThenATimedFinalStayOneUtterance() {
    // Partials without timing report 0; the final carries real timestamps.
    assertTranscript([
      Hypothesis("I did twenty", start: 0),
      Hypothesis("I did twenty reps", start: 0),
      Hypothesis("I did 20 reps.", start: 2.4, ended: true),
    ], equals: "I did 20 reps.")
  }

  func testRewordedHypothesisRevisesTheOpenUtterance() {
    assertTranscript([
      Hypothesis("I did twenty", start: 0.5),
      Hypothesis("I did 20 wraps", start: 0.5),
      Hypothesis("I did 20 reps", start: 0.5),
    ], equals: "I did 20 reps")
  }

  func testMetadataCommitStartsTheNextUtterance() {
    assertTranscript([
      Hypothesis("I did 20 reps", start: 0.5),
      Hypothesis("I did 20 reps.", start: 0.5, ended: true),
      Hypothesis("Then", start: nil),
      Hypothesis("Then squats.", start: nil),
    ], equals: "I did 20 reps. Then squats.")
  }

  func testShortUtteranceAfterMetadataCommitIsKept() {
    assertTranscript([
      Hypothesis("Okay.", start: nil, ended: true),
      Hypothesis("Today", start: nil),
    ], equals: "Okay. Today")
  }

  func testDuplicateFinalAfterCommitIsIgnored() {
    assertTranscript([
      Hypothesis("i did 20 reps", start: 0.5, ended: true),
      Hypothesis("I did 20 reps.", start: 0.5, ended: true),
      Hypothesis("I did 20 reps.", start: 0.5, ended: true),
    ], equals: "I did 20 reps.")
  }

  func testCumulativeHypothesisAfterCommitDoesNotDuplicate() {
    // Recognizers that keep the whole task in one hypothesis but still
    // report metadata at a pause.
    assertTranscript([
      Hypothesis("I did 20 reps.", start: 0.5, ended: true),
      Hypothesis("I did 20 reps. Then squats", start: 0.5),
      Hypothesis("I did twenty reps. Then squats.", start: 0.5),
    ], equals: "I did twenty reps. Then squats.")
  }

  func testEmptyPartialsAreIgnored() {
    assertTranscript([
      Hypothesis("I did", start: 0.5),
      Hypothesis("", start: nil, segments: 0),
      Hypothesis("   ", start: nil, segments: 0),
      Hypothesis("I did 20", start: 0.5),
      Hypothesis(".", start: 0.5, segments: 1),
    ], equals: "I did 20")
  }

  func testEmptyFinalCommitsTheOpenUtterance() {
    assertTranscript([
      Hypothesis("I did 20 reps", start: nil),
      Hypothesis("", start: nil, segments: 0, ended: true),
      Hypothesis("Then", start: nil),
    ], equals: "I did 20 reps Then")
  }
}
