import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
  private let messageLabel = UILabel()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let retryButton = UIButton(type: .system)
  private var inbox: RecipeShareInbox?
  private var generation: String?
  private var loadTimeout: DispatchWorkItem?
  private lazy var handoff = RecipeShareHandoff(
    prepare: { [weak self] text in
      guard let inbox = self?.inbox, let generation = self?.generation else {
        throw RecipeShareInbox.InboxError.unavailable
      }
      try inbox.enqueue(text: text, generation: generation)
    },
    open: { [weak self] completion in self?.openEatova(completion: completion) },
    scheduleTimeout: { action in
      let work = DispatchWorkItem(block: action)
      DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
      return { work.cancel() }
    },
    onState: { [weak self] state in self?.render(state) }
  )

  override func viewDidLoad() {
    super.viewDidLoad()
    configureView()
    let timeout = DispatchWorkItem { [weak self] in self?.handoff.loadingFailed(.unavailable) }
    loadTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    do {
      let sharedInbox = try RecipeShareInbox.shared()
      generation = try sharedInbox.generation()
      inbox = sharedInbox
      let items = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).prefix(8)
      let providers = Array(items.flatMap { $0.attachments ?? [] }.prefix(8))
      let initial = items.compactMap { $0.attributedContentText?.string }
      guard initial.reduce(0, { $0 + $1.utf16.count }) <= RecipeShareInbox.maxTextLength else {
        handoff.loadingFailed(.invalidSource)
        return
      }
      load(providers, at: 0, parts: initial)
    } catch {
      handoff.loadingFailed(.unavailable)
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    handoff.appeared()
  }

  private func configureView() {
    view.backgroundColor = .systemBackground
    preferredContentSize = CGSize(width: 420, height: 260)
    let titleLabel = UILabel()
    titleLabel.text = localized("share.title")
    titleLabel.font = .preferredFont(forTextStyle: .title2)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.numberOfLines = 0
    messageLabel.text = localized("share.opening")
    messageLabel.font = .preferredFont(forTextStyle: .body)
    messageLabel.adjustsFontForContentSizeCategory = true
    messageLabel.numberOfLines = 0
    spinner.startAnimating()
    retryButton.setTitle(localized("share.retry"), for: .normal)
    retryButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
    retryButton.titleLabel?.adjustsFontForContentSizeCategory = true
    retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
    retryButton.isHidden = true
    let closeButton = UIButton(type: .system)
    closeButton.setTitle(localized("share.cancel"), for: .normal)
    closeButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
    closeButton.titleLabel?.adjustsFontForContentSizeCategory = true
    closeButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
    let stack = UIStackView(arrangedSubviews: [titleLabel, messageLabel, spinner, retryButton, closeButton])
    stack.axis = .vertical
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    let scrollView = UIScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scrollView)
    scrollView.addSubview(stack)
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -12),
      stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -48),
      retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
      closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
    ])
  }

  private func load(_ providers: [NSItemProvider], at index: Int, parts: [String]) {
    guard handoff.state == .loading else { return }
    guard index < providers.count else {
      var unique: [String] = []
      for part in parts where !unique.contains(part) { unique.append(part) }
      loadTimeout?.cancel()
      handoff.received(text: unique.joined(separator: "\n\n"))
      return
    }
    let provider = providers[index]
    let type: String
    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
      type = UTType.url.identifier
    } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
      type = UTType.plainText.identifier
    } else {
      load(providers, at: index + 1, parts: parts)
      return
    }
    provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] item, error in
      var value: String?
      if let url = item as? URL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
        value = url.absoluteString
      } else if let string = item as? String {
        value = string
      }
      DispatchQueue.main.async {
        guard let self = self, self.handoff.state == .loading else { return }
        guard error == nil else {
          self.handoff.loadingFailed(.unavailable)
          return
        }
        var next = parts
        if let text = value {
          guard text.utf16.count <= RecipeShareInbox.maxTextLength,
            next.reduce(text.utf16.count, { $0 + $1.utf16.count }) <= RecipeShareInbox.maxTextLength else {
            self.handoff.loadingFailed(.invalidSource)
            return
          }
          next.append(text)
        }
        self.load(providers, at: index + 1, parts: next)
      }
    }
  }

  private func openEatova(completion: @escaping (Bool) -> Void) {
    // Public API, but opening the containing app from a Share Extension is not
    // an Apple-supported contract. Keep the result/timeout failure path visible.
    var responder: UIResponder? = self
    while let current = responder {
      if let application = current as? UIApplication {
        application.open(RecipeShareWake.url, options: [:], completionHandler: completion)
        return
      }
      responder = current.next
    }
    completion(false)
  }

  private func render(_ state: RecipeShareHandoff.State) {
    retryButton.isHidden = state != .failed(.openFailed)
    if state == .loading || state == .opening {
      spinner.startAnimating()
      messageLabel.text = localized("share.opening")
      return
    }
    loadTimeout?.cancel()
    spinner.stopAnimating()
    switch state {
    case .failed(let failure):
      let key: String
      switch failure {
      case .invalidSource: key = "share.invalid"
      case .unavailable: key = "share.unavailable"
      case .full: key = "share.full"
      case .accountChanged: key = "share.accountChanged"
      case .openFailed: key = "share.openFailed"
      }
      messageLabel.text = localized(key)
      UIAccessibility.post(notification: .announcement, argument: messageLabel.text)
    case .completed, .cancelled:
      extensionContext?.completeRequest(returningItems: nil)
    case .loading, .opening: break
    }
  }

  @objc private func retry() { handoff.retry() }

  @objc private func cancel() { handoff.cancel() }

  private func localized(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "Recipe share extension")
  }
}