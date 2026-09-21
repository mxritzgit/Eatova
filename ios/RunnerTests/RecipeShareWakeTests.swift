import XCTest
@testable import Runner

final class RecipeShareWakeTests: XCTestCase {
  func testExactWakeURLHasNoPayload() {
    XCTAssertEqual(RecipeShareWake.url.absoluteString, "eatova-share://import")
    XCTAssertEqual(RecipeShareWake.classify(RecipeShareWake.url), .wake)
    XCTAssertNil(RecipeShareWake.url.query)
    XCTAssertNil(RecipeShareWake.url.fragment)
    XCTAssertNil(RecipeShareWake.url.user)
    XCTAssertNil(RecipeShareWake.url.password)
  }

  func testMalformedReservedURLsNeverWakeOrForward() throws {
    let values = [
      "eatova-share://import?source=https://example.com",
      "eatova-share://import?owner=someone",
      "eatova-share://import?",
      "eatova-share://import#recipe",
      "eatova-share://user:password@import",
      "eatova-share://import:443",
      "eatova-share://import/",
      "eatova-share://IMPORT",
      "EATOVA-SHARE://import",
      "eatova-share://other",
      "eatova-share:import",
      "eatova-share://%69mport",
    ]
    for value in values {
      let url = try XCTUnwrap(URL(string: value))
      XCTAssertEqual(RecipeShareWake.classify(url), .invalid, value)
      XCTAssertTrue(RecipeShareWake.route([url]) { XCTFail("Invalid URL woke the receiver") }.isEmpty)
    }
  }

  func testUnrelatedOAuthAndWebURLsAreForwardedUnchanged() throws {
    let values = [
      "eatova://login-callback/?code=test-code",
      "com.googleusercontent.apps.test:/oauth2redirect?code=test-code",
      "https://example.com/recipe",
      "foreign://import",
      "eatova-share-other://import",
    ]
    let urls = try values.map { try XCTUnwrap(URL(string: $0)) }
    XCTAssertTrue(urls.allSatisfy { RecipeShareWake.classify($0) == .unrelated })
    XCTAssertEqual(RecipeShareWake.route(urls) { XCTFail("Unrelated URL woke the receiver") }, urls)
  }

  func testMixedContextWakesOnceAndPreservesOAuthContext() throws {
    let oauth = try XCTUnwrap(URL(string: "eatova://login-callback/?code=test-code"))
    let invalid = try XCTUnwrap(URL(string: "eatova-share://import?token=not-accepted"))
    var notifications = 0
    let forwarded = RecipeShareWake.route([RecipeShareWake.url, oauth, invalid, RecipeShareWake.url]) {
      notifications += 1
    }
    XCTAssertEqual(notifications, 1)
    XCTAssertEqual(forwarded, [oauth])
  }

  func testEmptyContextDoesNothing() {
    XCTAssertTrue(RecipeShareWake.route([]) { XCTFail("Empty context woke the receiver") }.isEmpty)
  }
}
