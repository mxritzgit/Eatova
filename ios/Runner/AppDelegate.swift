import AVFoundation
import Flutter
import Speech
import UIKit
import UserNotifications
import os.log
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    WorkmanagerPlugin.registerBGProcessingTask(withIdentifier: "com.eatova.app.sync")
    WorkmanagerPlugin.registerLaunchHandlers()
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    // PROD-1: flutter_local_notifications needs this delegate so local nudges
    // show in the foreground and tap callbacks arrive. Local only, no APNs.
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Under the UIScene lifecycle window?.rootViewController does not exist yet
  // in didFinishLaunchingWithOptions; this callback is the reliable place to
  // reach the plugin registry.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "EatovaSpeechPlugin") {
      EatovaSpeechPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "EatovaSecureScreenPlugin") {
      EatovaSecureScreenPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "EatovaScreenPlugin") {
      EatovaScreenPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "RecipeSharePlugin") {
      RecipeSharePlugin.register(with: registrar)
    }
  }
}

// ---------------------------------------------------------------------------
// EatovaSecureScreenPlugin: iOS counterpart to Android's FLAG_SECURE
// (security audit 2026-08-09).
//
// iOS has no FLAG_SECURE. The target is the app-switcher preview snapshot:
// while a sensitive screen is active, an opaque cover goes over the window on
// resign-active and is removed on become-active, so the snapshot shows only it.
// ---------------------------------------------------------------------------
public final class EatovaSecureScreenPlugin: NSObject, FlutterPlugin {
  private var secure = false
  private var coverView: UIView?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "eatova/secure_screen",
      binaryMessenger: registrar.messenger()
    )
    let instance = EatovaSecureScreenPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    NotificationCenter.default.addObserver(
      instance,
      selector: #selector(willResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      instance,
      selector: #selector(didBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "enable":
      secure = true
      result(nil)
    case "disable":
      secure = false
      removeCover()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  @objc private func willResignActive() {
    guard secure, let window = activeWindow() else { return }
    let cover = UIView(frame: window.bounds)
    // Eatova base tone #0B0D11 so the cover does not read as an error.
    cover.backgroundColor = UIColor(red: 0.043, green: 0.051, blue: 0.067, alpha: 1)
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    blur.frame = cover.bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    cover.addSubview(blur)
    window.addSubview(cover)
    coverView = cover
  }

  @objc private func didBecomeActive() {
    removeCover()
  }

  private func removeCover() {
    coverView?.removeFromSuperview()
    coverView = nil
  }

  private func activeWindow() -> UIWindow? {
    let keyed = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
    if let keyed = keyed { return keyed }
    return UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first
  }
}

// ---------------------------------------------------------------------------
// EatovaSpeechPlugin: native voice-input bridge for the coach chat and the
// meal description.
//
// Requests mic + speech permission, runs AVAudioEngine + SFSpeechRecognizer
// and reports the transcript to Flutter (lib/src/services/speech_input.dart):
// - listen {localeId, token, vocabulary?, maxUnits?} completes with
//   {text, reason}. vocabulary is gym (default) or food; maxUnits defaults to
//   1000, so calls without them behave as before. reason is stop (Dart
//   asked), final (the task ended on its own), limit (it ended on its own
//   after >= 55 s, Apple's server cap), length (the text reached maxUnits) or
//   cancel. Errors: permission_denied, unavailable, busy, recognition_failed.
// - Native -> Dart partial {token, text}: the whole transcript so far, sent
//   only when it changed.
// - stop is graceful: the audio ends and the final result gets up to 1.5 s.
//   cancel completes at once (lifecycle, dispose).
// The transcript is never logged.
// ---------------------------------------------------------------------------
public final class EatovaSpeechPlugin: NSObject, FlutterPlugin {
  /// Default for listen's maxUnits; mirrors kCoachMaxInputChars (UTF-16
  /// units) in coach_composer.dart.
  private static let defaultMaxTranscriptUnits = 1000
  private static let finalResultGrace: TimeInterval = 1.5
  /// Apple's server path stops a task after about one minute.
  private static let serverLimit: TimeInterval = 55
  /// Gym vocabulary in both app languages; it only biases recognition.
  private static let gymVocabulary = [
    "Bankdrücken", "Kniebeugen", "Kreuzheben", "Schulterdrücken", "Klimmzüge",
    "Liegestütze", "Rudern", "Latziehen", "Beinpresse", "Ausfallschritte",
    "Wiederholungen", "Sätze", "Langhantel", "Kurzhantel", "Kilo",
    "bench press", "squats", "deadlift", "overhead press", "pull-ups",
    "push-ups", "rows", "lat pulldown", "leg press", "lunges",
    "reps", "sets", "barbell", "dumbbell", "kg", "plank",
  ]
  /// Food, units and German store and brand words recognizers mishear, for
  /// the meal description; it only biases recognition.
  private static let foodVocabulary: [String] = [
    "Nutella", "Skyr", "Magerquark", "Haferflocken", "Hähnchenbrust",
    "Putenbrust", "Toastbrot", "Vollkornbrot", "Brötchen", "Müsli",
    "Joghurt", "Frischkäse", "Hüttenkäse", "Erdnussbutter", "Proteinpulver",
    "Proteinriegel", "Reiswaffeln", "Rührei", "Banane", "Heidelbeeren",
    "Basmatireis", "Vollkornnudeln", "Süßkartoffel", "Brokkoli", "Döner",
    "Schnitzel", "Leberkäse", "Brezel",
    "Gramm", "Milliliter", "Scheibe", "Esslöffel", "Teelöffel",
    "Portion", "Handvoll", "Becher", "Stück",
    "Lidl", "Aldi", "Rewe", "Edeka", "Kaufland", "Netto", "Penny",
    "Milbona", "Ehrmann", "Alpro",
    "grams", "slice", "tablespoon", "teaspoon", "cup", "handful",
    "oatmeal", "chicken breast", "Greek yogurt", "cottage cheese",
    "peanut butter", "protein shake", "whey", "rice cakes", "scrambled eggs",
  ]

  private let audioEngine = AVAudioEngine()
  private var channel: FlutterMethodChannel?
  private var recognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var pendingResult: FlutterResult?
  private var activeSessionID: UUID?
  private var tapInstalled = false
  private var transcript = SpeechTranscriptAccumulator()
  private var lastSentText = ""
  private var dartToken = 0
  /// Per listen call; read while recognizing.
  private var contextualStrings = EatovaSpeechPlugin.gymVocabulary
  private var maxTranscriptUnits = EatovaSpeechPlugin.defaultMaxTranscriptUnits
  /// Set while a graceful stop waits for the final result.
  private var stopReason: String?
  /// Wall clock when the audio engine started. Not the boot-time clock: that
  /// is a required-reason API PrivacyInfo.xcprivacy does not declare.
  private var recordingStartedAt: Date?

  /// Diagnostic log for the recognition mode: only a bool + locale id,
  /// never audio, transcript or PII.
  private static let speechLog = OSLog(subsystem: "com.eatova.app", category: "speech")

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "eatova/speech",
      binaryMessenger: registrar.messenger()
    )
    let instance = EatovaSpeechPlugin()
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "listen":
      let args = call.arguments as? [String: Any]
      let localeId = args?["localeId"] as? String ?? "de_DE"
      let token = args?["token"] as? Int ?? 0
      // Both optional: a call without them gets the coach's settings.
      let vocabulary = (args?["vocabulary"] as? String) == "food"
        ? Self.foodVocabulary
        : Self.gymVocabulary
      let requestedUnits = args?["maxUnits"] as? Int ?? Self.defaultMaxTranscriptUnits
      let maxUnits = requestedUnits > 0 ? requestedUnits : Self.defaultMaxTranscriptUnits
      listen(
        localeId: localeId,
        token: token,
        vocabulary: vocabulary,
        maxUnits: maxUnits,
        result: result
      )
    case "stop":
      DispatchQueue.main.async {
        self.beginGracefulStop(reason: "stop")
      }
      result(nil)
    case "cancel":
      DispatchQueue.main.async {
        self.cancel()
      }
      result(nil)
    case "available":
      // Same locale logic as "listen": caller may pass a language, default de_DE.
      let args = call.arguments as? [String: Any]
      let localeId = args?["localeId"] as? String ?? "de_DE"
      let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId))
      result(recognizer?.isAvailable ?? false)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func listen(
    localeId: String,
    token: Int,
    vocabulary: [String],
    maxUnits: Int,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.main.async {
      if self.pendingResult != nil {
        // Only a dictation that is draining its final result gives way; Dart
        // drops the old result by its token.
        guard let reason = self.stopReason else {
          result(FlutterError(
            code: "busy",
            message: "Spracherkennung laeuft bereits.",
            details: nil
          ))
          return
        }
        self.finish(text: self.transcript.text, reason: reason)
      }
      self.pendingResult = result
      self.transcript = SpeechTranscriptAccumulator()
      self.lastSentText = ""
      self.dartToken = token
      self.contextualStrings = vocabulary
      self.maxTranscriptUnits = maxUnits
      self.recordingStartedAt = nil
      let sessionID = UUID()
      self.activeSessionID = sessionID
      self.requestSpeechAuthorization(localeId: localeId, sessionID: sessionID)
    }
  }

  /// Ends the audio and gives the recognizer up to 1.5 s for its final result.
  private func beginGracefulStop(reason: String) {
    guard let sessionID = activeSessionID, pendingResult != nil, stopReason == nil else { return }
    guard let request = recognitionRequest else {
      // Still asking for permission: there is no audio to drain.
      finish(text: transcript.text, reason: reason)
      return
    }
    stopReason = reason
    stopAudioInput()
    request.endAudio()
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.finalResultGrace) {
      guard self.isCurrentSession(sessionID) else { return }
      self.finish(text: self.transcript.text, reason: reason)
    }
  }

  /// Immediate end for lifecycle paths; returns what was recognised so far.
  private func cancel() {
    guard pendingResult != nil else { return }
    finish(text: transcript.text, reason: "cancel")
  }

  private func isCurrentSession(_ sessionID: UUID) -> Bool {
    activeSessionID == sessionID && pendingResult != nil
  }

  private func requestSpeechAuthorization(localeId: String, sessionID: UUID) {
    SFSpeechRecognizer.requestAuthorization { status in
      DispatchQueue.main.async {
        guard self.isCurrentSession(sessionID) else { return }
        switch status {
        case .authorized:
          let completion: @Sendable (Bool) -> Void = { granted in
            DispatchQueue.main.async {
              guard self.isCurrentSession(sessionID) else { return }
              guard granted else {
                self.finish(errorCode: "permission_denied", message: "Mikrofon wurde nicht erlaubt.")
                return
              }
              self.startRecognition(localeId: localeId, sessionID: sessionID)
            }
          }
          if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: completion)
          } else {
            AVAudioSession.sharedInstance().requestRecordPermission(completion)
          }
        case .denied, .restricted:
          self.finish(errorCode: "permission_denied", message: "Spracherkennung wurde nicht erlaubt.")
        case .notDetermined:
          self.finish(errorCode: "permission_denied", message: "Spracherkennung muss noch freigegeben werden.")
        @unknown default:
          self.finish(errorCode: "permission_denied", message: "Spracherkennung wurde nicht erlaubt.")
        }
      }
    }
  }

  private func startRecognition(localeId: String, sessionID: UUID) {
    guard isCurrentSession(sessionID) else { return }
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId)) else {
      finish(errorCode: "unavailable", message: "Spracherkennung ist fuer diese Sprache nicht installiert.")
      return
    }
    guard recognizer.isAvailable else {
      finish(errorCode: "unavailable", message: "Spracherkennung ist gerade nicht verfuegbar.")
      return
    }

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
      try session.setActive(true, options: .notifyOthersOnDeactivation)

      let request = SFSpeechAudioBufferRecognitionRequest()
      request.shouldReportPartialResults = true
      request.taskHint = .dictation
      request.contextualStrings = contextualStrings
      if #available(iOS 16.0, *) {
        request.addsPunctuation = true
      }
      // Privacy: with an on-device model for this exact locale the audio never
      // leaves the device; without one the default `false` keeps the previous
      // server-side path. Never fail hard here. `supportsOnDeviceRecognition`
      // is an INSTANCE property, read only after the isAvailable guard above.
      let usesOnDevice = recognizer.supportsOnDeviceRecognition
      request.requiresOnDeviceRecognition = usesOnDevice
      os_log(
        "recognition mode=%{public}@ locale=%{public}@",
        log: Self.speechLog,
        type: .info,
        usesOnDevice ? "on-device" : "server",
        localeId
      )
      // Kept until finish, like Apple's SpokenWord sample.
      self.recognizer = recognizer
      recognitionRequest = request

      let inputNode = audioEngine.inputNode
      if tapInstalled {
        inputNode.removeTap(onBus: 0)
        tapInstalled = false
      }
      let format = inputNode.outputFormat(forBus: 0)
      // F3: `installTap` asserts on 0 Hz / 0 channels and raises an ObjC
      // NSException, i.e. SIGABRT — the surrounding `do/catch` only sees Swift
      // errors, so the app would die mid-chat. An empty format is the normal
      // state without a usable input route (mic held by another app, call,
      // Bluetooth/CarPlay switch, simulator); the session is already active, so
      // 0 Hz means "no route", not "not ready yet".
      //
      // `unavailable` is deliberate: speech_input.dart matches that code and
      // the UI shows a friendly message, while `recognition_failed` would
      // fall into the generic branch and leak a technical one. Cleanup runs via
      // finish -> cleanupAudio, which deactivates the session for a fresh route.
      guard format.sampleRate > 0, format.channelCount > 0 else {
        finish(
          errorCode: "unavailable",
          message: "Kein nutzbarer Mikrofon-Eingang. Beende laufende Anrufe oder andere Aufnahmen und versuche es erneut."
        )
        return
      }
      inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        request.append(buffer)
      }
      tapInstalled = true

      recognitionTask = recognizer.recognitionTask(with: request) { [weak self] speechResult, error in
        guard let self = self else { return }
        // Only plain values cross to the main queue.
        let best = speechResult?.bestTranscription
        let text = best?.formattedString
        let firstSegmentStart = best?.segments.first?.timestamp
        let segmentCount = best?.segments.count ?? 0
        let isFinal = speechResult?.isFinal ?? false
        // Some iOS versions end an utterance at a pause with metadata, no isFinal.
        let utteranceEnded = isFinal || speechResult?.speechRecognitionMetadata != nil
        let errorMessage = error?.localizedDescription
        DispatchQueue.main.async {
          guard self.isCurrentSession(sessionID) else { return }
          if let text = text {
            self.transcript.apply(
              text: text,
              firstSegmentStart: firstSegmentStart,
              segmentCount: segmentCount,
              utteranceEnded: utteranceEnded
            )
            self.sendPartialIfChanged()
          }
          if isFinal || errorMessage != nil {
            self.recognitionEnded(errorMessage: errorMessage)
          } else if self.transcript.text.utf16.count >= self.maxTranscriptUnits {
            self.beginGracefulStop(reason: "length")
          }
        }
      }

      audioEngine.prepare()
      try audioEngine.start()
      recordingStartedAt = Date()
    } catch {
      finish(errorCode: "recognition_failed", message: error.localizedDescription)
    }
  }

  /// The task delivered its final result or failed.
  private func recognitionEnded(errorMessage: String?) {
    if let reason = stopReason {
      // Draining after stop: even a late error returns what was recognised.
      finish(text: transcript.text, reason: reason)
    } else if let message = errorMessage, transcript.text.isEmpty {
      finish(errorCode: "recognition_failed", message: message)
    } else {
      let elapsed = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
      finish(text: transcript.text, reason: elapsed >= Self.serverLimit ? "limit" : "final")
    }
  }

  /// Main thread only. Sends the whole transcript so Dart can replace its preview.
  private func sendPartialIfChanged() {
    let text = transcript.text
    guard text != lastSentText else { return }
    lastSentText = text
    let arguments: [String: Any] = ["token": dartToken, "text": text]
    channel?.invokeMethod("partial", arguments: arguments)
  }

  private func finish(text: String, reason: String) {
    let value: [String: Any] = ["text": text, "reason": reason]
    finish(result: value)
  }

  private func finish(errorCode: String, message: String) {
    finish(result: FlutterError(code: errorCode, message: message, details: nil))
  }

  private func finish(result value: Any) {
    guard let result = pendingResult else { return }
    // Invalidate before endAudio/cancel can deliver callbacks from this task.
    // A later permission or recognition callback must not restart recording
    // or complete a subsequent listen call.
    activeSessionID = nil
    pendingResult = nil
    stopReason = nil
    cleanupAudio()
    result(value)
  }

  private func stopAudioInput() {
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    if tapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
  }

  private func cleanupAudio() {
    stopAudioInput()
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest = nil
    recognizer = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}

// ---------------------------------------------------------------------------
// EatovaScreenPlugin: keeps the screen awake while Dart asks for it (rest
// before a timed interval, dictation). Channel eatova/screen, method
// setKeepAwake {on: Bool}; no permission involved.
// ---------------------------------------------------------------------------
public final class EatovaScreenPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "eatova/screen",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(EatovaScreenPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setKeepAwake":
      guard let on = (call.arguments as? [String: Any])?["on"] as? Bool else {
        result(FlutterError(code: "invalid_args", message: "setKeepAwake expects {on: Bool}.", details: nil))
        return
      }
      // Method calls arrive on the main thread, which UIApplication requires.
      UIApplication.shared.isIdleTimerDisabled = on
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
