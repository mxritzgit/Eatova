import Foundation

/// Main-thread state for one extension request; retries never enqueue twice.
final class RecipeShareHandoff {
  enum Failure: Equatable { case invalidSource, unavailable, full, accountChanged, openFailed }
  enum State: Equatable { case loading, opening, failed(Failure), completed, cancelled }
  typealias ScheduleTimeout = (@escaping () -> Void) -> (() -> Void)

  private let prepare: (String) throws -> Void
  private let open: (@escaping (Bool) -> Void) -> Void
  private let scheduleTimeout: ScheduleTimeout
  private let onState: (State) -> Void
  private var source: String?
  private var visible = false
  private var prepared = false
  private var attempt = 0
  private var cancelTimeout: (() -> Void)?
  private(set) var state: State = .loading

  init(
    prepare: @escaping (String) throws -> Void,
    open: @escaping (@escaping (Bool) -> Void) -> Void,
    scheduleTimeout: @escaping ScheduleTimeout,
    onState: @escaping (State) -> Void
  ) {
    self.prepare = prepare
    self.open = open
    self.scheduleTimeout = scheduleTimeout
    self.onState = onState
  }

  func appeared() {
    visible = true
    guard state == .loading else { return }
    startIfReady()
  }

  func received(text: String) {
    guard state == .loading, source == nil else { return }
    guard let valid = RecipeShareInbox.validatedText(text) else {
      loadingFailed(.invalidSource)
      return
    }
    source = valid
    startIfReady()
  }

  func loadingFailed(_ failure: Failure) {
    guard state == .loading else { return }
    transition(.failed(failure))
  }

  func retry() {
    guard state == .failed(.openFailed) else { return }
    startIfReady()
  }

  func cancel() {
    guard state != .completed, state != .cancelled else { return }
    attempt += 1
    cancelTimeout?()
    cancelTimeout = nil
    transition(.cancelled)
  }

  private func startIfReady() {
    guard visible, let source = source,
      state == .loading || state == .failed(.openFailed) else { return }
    transition(.opening)
    if !prepared {
      do {
        try prepare(source)
        prepared = true
      } catch RecipeShareInbox.InboxError.full {
        transition(.failed(.full))
        return
      } catch RecipeShareInbox.InboxError.accountChanged {
        transition(.failed(.accountChanged))
        return
      } catch RecipeShareInbox.InboxError.invalidText {
        transition(.failed(.invalidSource))
        return
      } catch {
        transition(.failed(.unavailable))
        return
      }
    }
    attempt += 1
    let current = attempt
    cancelTimeout = scheduleTimeout { [weak self] in
      self?.finished(opened: false, attempt: current)
    }
    open { [weak self] opened in self?.finished(opened: opened, attempt: current) }
  }

  private func finished(opened: Bool, attempt expected: Int) {
    guard state == .opening, attempt == expected else { return }
    cancelTimeout?()
    cancelTimeout = nil
    transition(opened ? .completed : .failed(.openFailed))
  }

  private func transition(_ next: State) {
    state = next
    onState(next)
  }
}
