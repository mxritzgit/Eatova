import XCTest
@testable import Runner

final class RecipeShareHandoffTests: XCTestCase {
  private final class Harness {
    var prepared: [String] = []
    var completions: [(Bool) -> Void] = []
    var deadlines: [() -> Void] = []
    var cancelledDeadlines = 0
    var states: [RecipeShareHandoff.State] = []
    var preparationError: Error?
    lazy var handoff = RecipeShareHandoff(
      prepare: { [unowned self] text in
        if let error = preparationError { throw error }
        prepared.append(text)
      },
      open: { [unowned self] completion in completions.append(completion) },
      scheduleTimeout: { [unowned self] deadline in
        deadlines.append(deadline)
        return { [weak self] in self?.cancelledDeadlines += 1 }
      },
      onState: { [unowned self] state in states.append(state) }
    )
  }

  func testLoadedSourceWaitsUntilControllerAppears() {
    let harness = Harness()
    harness.handoff.received(text: "  Shared recipe  ")
    XCTAssertTrue(harness.prepared.isEmpty)
    XCTAssertTrue(harness.completions.isEmpty)
    harness.handoff.appeared()
    XCTAssertEqual(harness.prepared, ["Shared recipe"])
    XCTAssertEqual(harness.completions.count, 1)
    XCTAssertEqual(harness.handoff.state, .opening)
  }

  func testAppearanceWaitsForSourceAndSuccessCompletesOnlyOnce() {
    let harness = Harness()
    harness.handoff.appeared()
    XCTAssertTrue(harness.completions.isEmpty)
    harness.handoff.received(text: "Recipe")
    XCTAssertFalse(harness.states.contains(.completed))
    harness.handoff.appeared()
    harness.handoff.received(text: "Duplicate")
    harness.completions[0](true)
    harness.completions[0](true)
    XCTAssertEqual(harness.prepared, ["Recipe"])
    XCTAssertEqual(harness.completions.count, 1)
    XCTAssertEqual(harness.states.filter { $0 == .completed }.count, 1)
    XCTAssertEqual(harness.cancelledDeadlines, 1)
  }

  func testRejectedOpenRetriesWithoutEnqueuingAgain() {
    let harness = Harness()
    harness.handoff.appeared()
    harness.handoff.received(text: "Recipe")
    harness.completions[0](false)
    XCTAssertEqual(harness.handoff.state, .failed(.openFailed))
    harness.handoff.appeared()
    XCTAssertEqual(harness.completions.count, 1)
    harness.handoff.retry()
    harness.handoff.retry()
    XCTAssertEqual(harness.completions.count, 2)
    XCTAssertEqual(harness.prepared, ["Recipe"])
    harness.completions[1](true)
    XCTAssertEqual(harness.handoff.state, .completed)
  }

  func testTimeoutAndRetryIgnoreEarlierCompletionAndDeadline() {
    let harness = Harness()
    harness.handoff.received(text: "Recipe")
    harness.handoff.appeared()
    harness.deadlines[0]()
    harness.completions[0](true)
    XCTAssertEqual(harness.handoff.state, .failed(.openFailed))
    harness.handoff.retry()
    harness.completions[0](true)
    harness.deadlines[0]()
    XCTAssertEqual(harness.handoff.state, .opening)
    harness.completions[1](true)
    harness.deadlines[1]()
    XCTAssertEqual(harness.handoff.state, .completed)
    XCTAssertEqual(harness.prepared.count, 1)
  }

  func testCancellationBeforeLoadNeverStoresOrOpens() {
    let harness = Harness()
    harness.handoff.cancel()
    harness.handoff.received(text: "Late recipe")
    harness.handoff.appeared()
    harness.handoff.retry()
    XCTAssertEqual(harness.handoff.state, .cancelled)
    XCTAssertTrue(harness.prepared.isEmpty)
    XCTAssertTrue(harness.completions.isEmpty)
  }

  func testCancellationWhileOpeningIgnoresLateCallbacks() {
    let harness = Harness()
    harness.handoff.appeared()
    harness.handoff.received(text: "Recipe")
    harness.handoff.cancel()
    harness.completions[0](true)
    harness.deadlines[0]()
    harness.handoff.retry()
    XCTAssertEqual(harness.handoff.state, .cancelled)
    XCTAssertFalse(harness.states.contains(.completed))
    XCTAssertEqual(harness.prepared.count, 1)
  }

  func testUnreadableOrTimedOutLoadIgnoresDelayedProvider() {
    let harness = Harness()
    harness.handoff.appeared()
    harness.handoff.loadingFailed(.unavailable)
    harness.handoff.received(text: "Late recipe")
    XCTAssertEqual(harness.handoff.state, .failed(.unavailable))
    XCTAssertTrue(harness.prepared.isEmpty)
    XCTAssertTrue(harness.completions.isEmpty)
  }

  func testInvalidSourceNeverTouchesInboxOrOpens() {
    for source in ["  ", "Recipe\0text", String(repeating: "x", count: 20001)] {
      let harness = Harness()
      harness.handoff.appeared()
      harness.handoff.received(text: source)
      XCTAssertEqual(harness.handoff.state, .failed(.invalidSource))
      XCTAssertTrue(harness.prepared.isEmpty)
      XCTAssertTrue(harness.completions.isEmpty)
    }
  }

  func testInboxFailuresNeverOpenOrRetryWithStaleAccount() {
    let cases: [(RecipeShareInbox.InboxError, RecipeShareHandoff.Failure)] = [
      (.full, .full), (.accountChanged, .accountChanged),
      (.invalidText, .invalidSource), (.unavailable, .unavailable)
    ]
    for (error, failure) in cases {
      let harness = Harness()
      harness.preparationError = error
      harness.handoff.appeared()
      harness.handoff.received(text: "Recipe")
      harness.handoff.retry()
      XCTAssertEqual(harness.handoff.state, .failed(failure))
      XCTAssertTrue(harness.prepared.isEmpty)
      XCTAssertTrue(harness.completions.isEmpty)
    }
  }
}
