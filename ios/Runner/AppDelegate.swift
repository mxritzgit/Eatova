import AVFoundation
import Flutter
import Speech
import UIKit
import UserNotifications
import os.log

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
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
// EatovaSpeechPlugin: native voice-input bridge for the coach chat.
//
// Requests mic + speech permission, runs AVAudioEngine + SFSpeechRecognizer
// and returns the transcript to Flutter.
// ---------------------------------------------------------------------------
public final class EatovaSpeechPlugin: NSObject, FlutterPlugin {
  private let audioEngine = AVAudioEngine()
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var pendingResult: FlutterResult?
  private var lastTranscription = ""
  private var isFinishing = false
  private var tapInstalled = false

  /// Diagnostic log for the recognition mode: only a bool + locale id,
  /// never audio, transcript or PII.
  private static let speechLog = OSLog(subsystem: "com.eatova.app", category: "speech")

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "eatova/speech",
      binaryMessenger: registrar.messenger()
    )
    let instance = EatovaSpeechPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "listen":
      let args = call.arguments as? [String: Any]
      let localeId = args?["localeId"] as? String ?? "de_DE"
      listen(localeId: localeId, result: result)
    case "stop":
      stop()
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

  private func listen(localeId: String, result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard self.pendingResult == nil else {
        result(FlutterError(
          code: "busy",
          message: "Spracherkennung laeuft bereits.",
          details: nil
        ))
        return
      }
      self.pendingResult = result
      self.lastTranscription = ""
      self.isFinishing = false
      self.requestSpeechAuthorization(localeId: localeId)
    }
  }

  private func stop() {
    DispatchQueue.main.async {
      guard self.pendingResult != nil else { return }
      self.finish(success: self.lastTranscription)
    }
  }

  private func requestSpeechAuthorization(localeId: String) {
    SFSpeechRecognizer.requestAuthorization { status in
      DispatchQueue.main.async {
        switch status {
        case .authorized:
          AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
              guard granted else {
                self.finish(errorCode: "permission_denied", message: "Mikrofon wurde nicht erlaubt.")
                return
              }
              self.startRecognition(localeId: localeId)
            }
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

  private func startRecognition(localeId: String) {
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
      // `unavailable` is deliberate: coach_speech.dart:20 matches that code and
      // shows a friendly message, while `recognition_failed` would fall into
      // the generic branch and leak a technical one. Cleanup runs via
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
        DispatchQueue.main.async {
          if let speechResult = speechResult {
            self.lastTranscription = speechResult.bestTranscription.formattedString
            if speechResult.isFinal {
              self.finish(success: self.lastTranscription)
              return
            }
          }
          if let error = error {
            if self.lastTranscription.isEmpty {
              self.finish(errorCode: "recognition_failed", message: error.localizedDescription)
            } else {
              self.finish(success: self.lastTranscription)
            }
          }
        }
      }

      audioEngine.prepare()
      try audioEngine.start()
    } catch {
      finish(errorCode: "recognition_failed", message: error.localizedDescription)
    }
  }

  private func finish(success text: String) {
    guard !isFinishing else { return }
    isFinishing = true
    cleanupAudio()
    let result = pendingResult
    pendingResult = nil
    result?(text)
    isFinishing = false
  }

  private func finish(errorCode: String, message: String) {
    guard !isFinishing else { return }
    isFinishing = true
    cleanupAudio()
    let result = pendingResult
    pendingResult = nil
    result?(FlutterError(code: errorCode, message: message, details: nil))
    isFinishing = false
  }

  private func cleanupAudio() {
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    if tapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}
