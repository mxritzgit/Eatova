import Foundation

/// Shared only by Runner and the Share Extension; contains no session credentials.
final class RecipeShareInbox {
  static let appGroup = "group.com.eatova.app.recipe-share"
  static let maxTextLength = 20000
  static let maxPending = 8
  private let directory: URL
  private let now: () -> Date

  enum InboxError: Error {
    case unavailable, invalidText, full, accountChanged, invalidStorage
  }

  private struct Entry: Codable {
    let id: String
    let text: String
    let createdAt: Date
  }

  private struct State: Codable {
    var generation = UUID().uuidString
    var owner: String?
    var entries: [Entry] = []
  }

  init(directory: URL, now: @escaping () -> Date = Date.init) {
    self.directory = directory
    self.now = now
  }

  static func shared() throws -> RecipeShareInbox {
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroup
    ) else { throw InboxError.unavailable }
    return RecipeShareInbox(directory: container.appendingPathComponent("RecipeShareInbox", isDirectory: true))
  }

  func generation() throws -> String {
    try update { $0.generation }
  }

  func enqueue(text: String, generation: String) throws {
    guard let validated = Self.validatedText(text) else { throw InboxError.invalidText }
    try update { state in
      guard generation == state.generation else { throw InboxError.accountChanged }
      guard state.entries.count < Self.maxPending else { throw InboxError.full }
      state.entries.append(Entry(id: UUID().uuidString, text: validated, createdAt: now()))
    }
  }

  func consume(expectedOwner: String?) throws -> [[String: String]] {
    try update { state in
      if state.owner != expectedOwner {
        // This persisted comparison also protects a restart after a failed clear.
        if state.owner != nil { state.entries.removeAll() }
        state.generation = UUID().uuidString
        state.owner = expectedOwner
      }
      let result = state.entries.map { ["id": $0.id, "text": $0.text] }
      state.entries.removeAll()
      return result
    }
  }

  func clear(expectedOwner: String?) throws {
    try update { $0 = State(owner: expectedOwner) }
  }

  static func validOwner(_ owner: String?) -> Bool {
    guard let owner = owner else { return true }
    return owner.count == 64 && owner.allSatisfy { "0123456789abcdef".contains($0) }
  }

  static func validatedText(_ text: String) -> String? {
    guard text.utf16.count <= maxTextLength, !text.contains("\0") else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func update<T>(_ mutation: (inout State) throws -> T) throws -> T {
    let manager = FileManager.default
    try manager.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.complete]
    )
    var protectedDirectory = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try protectedDirectory.setResourceValues(values)
    let file = directory.appendingPathComponent("pending.json")
    var coordinationError: NSError?
    var operation: Result<T, Error>?
    NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: &coordinationError) { url in
      operation = Result {
        var state = State()
        if manager.fileExists(atPath: url.path) {
          let attributes = try manager.attributesOfItem(atPath: url.path)
          guard let size = attributes[.size] as? NSNumber, size.intValue <= 2_000_000 else {
            throw InboxError.invalidStorage
          }
          state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
          guard state.entries.count <= Self.maxPending, UUID(uuidString: state.generation) != nil,
            Self.validOwner(state.owner) else {
            throw InboxError.invalidStorage
          }
        }
        let time = now()
        state.entries.removeAll {
          Self.validatedText($0.text) == nil || UUID(uuidString: $0.id) == nil ||
            $0.createdAt > time.addingTimeInterval(60) ||
            $0.createdAt < time.addingTimeInterval(-86400)
        }
        let result = try mutation(&state)
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return result
      }
    }
    if let error = coordinationError { throw error }
    guard let result = operation else { throw InboxError.unavailable }
    return try result.get()
  }
}
