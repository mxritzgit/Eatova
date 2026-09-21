import XCTest
@testable import Runner

final class RecipeShareInboxTests: XCTestCase {
  private var directory: URL!
  private let fixedTime = Date(timeIntervalSince1970: 1_800_000_000)

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  override func tearDownWithError() throws {
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
  }

  func testSourceSurvivesAnotherInstanceAndConsumesOnce() throws {
    let inbox = RecipeShareInbox(directory: directory, now: { self.fixedTime })
    try inbox.enqueue(text: "  https://www.tiktok.com/@cook/video/123  ", generation: inbox.generation())
    let reopened = RecipeShareInbox(directory: directory, now: { self.fixedTime })
    let values = try reopened.consume(expectedOwner: nil)
    XCTAssertEqual(values.count, 1)
    XCTAssertEqual(values.first?["text"], "https://www.tiktok.com/@cook/video/123")
    XCTAssertTrue(try inbox.consume(expectedOwner: nil).isEmpty)
  }

  func testAccountChangeRejectsAlreadyOpenExtension() throws {
    let inbox = RecipeShareInbox(directory: directory, now: { self.fixedTime })
    let oldGeneration = try inbox.generation()
    try inbox.enqueue(text: "Old recipe", generation: oldGeneration)
    try inbox.clear(expectedOwner: nil)
    XCTAssertThrowsError(try inbox.enqueue(text: "Delayed source", generation: oldGeneration))
    XCTAssertTrue(try inbox.consume(expectedOwner: nil).isEmpty)
    try inbox.enqueue(text: "New recipe", generation: inbox.generation())
    XCTAssertEqual(try inbox.consume(expectedOwner: nil).first?["text"], "New recipe")
  }

  func testPendingSourcesExpireAfterOneDay() throws {
    let inbox = RecipeShareInbox(directory: directory, now: { self.fixedTime })
    try inbox.enqueue(text: "Recipe", generation: inbox.generation())
    let later = RecipeShareInbox(directory: directory, now: { self.fixedTime.addingTimeInterval(86401) })
    XCTAssertTrue(try later.consume(expectedOwner: nil).isEmpty)
  }

  func testRejectsOversizeEmptyAndNullByteSources() throws {
    let inbox = RecipeShareInbox(directory: directory, now: { self.fixedTime })
    let generation = try inbox.generation()
    for text in ["  ", "recipe\0text", String(repeating: "a", count: 20001)] {
      XCTAssertThrowsError(try inbox.enqueue(text: text, generation: generation))
    }
    XCTAssertTrue(try inbox.consume(expectedOwner: nil).isEmpty)
  }

  func testQueueLimitDoesNotEvictAnEarlierSource() throws {
    let inbox = RecipeShareInbox(directory: directory, now: { self.fixedTime })
    let generation = try inbox.generation()
    for index in 0..<8 { try inbox.enqueue(text: "Recipe \(index)", generation: generation) }
    XCTAssertThrowsError(try inbox.enqueue(text: "Overflow", generation: generation))
    let values = try inbox.consume(expectedOwner: nil)
    XCTAssertEqual(values.count, 8)
    XCTAssertEqual(values.first?["text"], "Recipe 0")
  }

  func testRestartWithDifferentOwnerDropsSourceAfterUnfinishedClear() throws {
    let ownerA = String(repeating: "a", count: 64)
    let ownerB = String(repeating: "b", count: 64)
    let inbox = RecipeShareInbox(directory: directory, now: { self.fixedTime })
    XCTAssertTrue(try inbox.consume(expectedOwner: ownerA).isEmpty)
    let oldGeneration = try inbox.generation()
    try inbox.enqueue(text: "Account A source", generation: oldGeneration)
    // A protected-file clear that fails before its write leaves this exact state.
    let restarted = RecipeShareInbox(directory: directory, now: { self.fixedTime })
    XCTAssertTrue(try restarted.consume(expectedOwner: ownerB).isEmpty)
    XCTAssertThrowsError(try inbox.enqueue(text: "Delayed A extension", generation: oldGeneration))
    try restarted.enqueue(text: "Account B source", generation: restarted.generation())
    XCTAssertEqual(try restarted.consume(expectedOwner: ownerB).first?["text"], "Account B source")
  }

  func testSameOwnerRestartPreservesSourceAndUnownedShareSurvivesFirstLogin() throws {
    let owner = String(repeating: "a", count: 64)
    let inbox = RecipeShareInbox(directory: directory, now: { self.fixedTime })
    try inbox.enqueue(text: "Before login", generation: inbox.generation())
    XCTAssertEqual(try inbox.consume(expectedOwner: owner).first?["text"], "Before login")
    try inbox.enqueue(text: "Signed-in source", generation: inbox.generation())
    let restarted = RecipeShareInbox(directory: directory, now: { self.fixedTime })
    XCTAssertEqual(try restarted.consume(expectedOwner: owner).first?["text"], "Signed-in source")
  }

  func testSignedOutRestartDiscardsPreviouslyOwnedSource() throws {
    let owner = String(repeating: "a", count: 64)
    let inbox = RecipeShareInbox(directory: directory, now: { self.fixedTime })
    _ = try inbox.consume(expectedOwner: owner)
    try inbox.enqueue(text: "Private source", generation: inbox.generation())
    let restarted = RecipeShareInbox(directory: directory, now: { self.fixedTime })
    XCTAssertTrue(try restarted.consume(expectedOwner: nil).isEmpty)
  }

}
