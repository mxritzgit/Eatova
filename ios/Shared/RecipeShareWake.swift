import Foundation

enum RecipeShareWake {
  static let scheme = "eatova-share"
  static let url = URL(string: "eatova-share://import")!
  static let notification = Notification.Name("com.eatova.app.recipeShareWake")

  enum Destination: Equatable {
    case wake
    case invalid
    case unrelated
  }

  static func classify(_ candidate: URL) -> Destination {
    guard candidate.scheme?.lowercased() == scheme else { return .unrelated }
    return candidate.absoluteString == url.absoluteString ? .wake : .invalid
  }

  // The URL carries no recipe data or identity. Only the bound inbox can provide those.
  static func route(_ candidates: [URL], notify: () -> Void) -> [URL] {
    var shouldWake = false
    let unrelated = candidates.filter { candidate in
      switch classify(candidate) {
      case .wake:
        shouldWake = true
        return false
      case .invalid:
        return false
      case .unrelated:
        return true
      }
    }
    if shouldWake { notify() }
    return unrelated
  }
}
