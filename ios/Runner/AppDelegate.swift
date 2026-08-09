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
    // PROD-1 (flutter_local_notifications, on-device): Das Plugin braucht den
    // UNUserNotificationCenter-Delegate auf dem AppDelegate, damit lokale
    // Nudges auch im Vordergrund angezeigt werden und Tap-Callbacks ankommen.
    // FlutterAppDelegate implementiert UNUserNotificationCenterDelegate bereits;
    // wir setzen hier nur die Zuweisung. Rein lokal, KEIN APNs/Remote-Push.
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Bei Scene-Lifecycle (UIScene) existiert window?.rootViewController in
  // didFinishLaunchingWithOptions noch nicht. Stattdessen wird die implizite
  // FlutterEngine ueber diesen Callback hochgezogen und liefert uns einen
  // Plugin-Registry-Zugang, mit dem wir den Speech-MethodChannel zuverlaessig
  // einhaengen koennen.
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
// EatovaSecureScreenPlugin: iOS-Gegenstueck zu Androids FLAG_SECURE
// (Sicherheits-Audit 2026-08-09).
//
// iOS kennt kein FLAG_SECURE. Der Angriff, den es hier zu schliessen gilt,
// ist das App-Switcher-Vorschaubild: iOS macht beim Wechsel in den
// Hintergrund einen Snapshot des Screens. Solange ein sensibler Screen
// (Auth-Code, Passwort, Gesundheitsdaten) aktiv ist, legen wir beim
// Deaktivieren eine blickdichte Abdeckung ueber das Fenster und entfernen
// sie beim Reaktivieren — der Snapshot zeigt dann nur die Abdeckung.
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
    // Eatova-Grundton #0B0D11, damit die Abdeckung nicht als Fehler wirkt.
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
// EatovaSpeechPlugin: nativer Sprach-Eingabe-Bruecke fuer den Coach-Chat.
//
// Holt sich Mikrofon- + Speech-Recognition-Berechtigung (loest die iOS-
// Permission-Popups aus), startet AVAudioEngine + SFSpeechRecognizer und
// liefert das erkannte Transkript an Flutter zurueck.
// ---------------------------------------------------------------------------
public final class EatovaSpeechPlugin: NSObject, FlutterPlugin {
  private let audioEngine = AVAudioEngine()
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var pendingResult: FlutterResult?
  private var lastTranscription = ""
  private var isFinishing = false
  private var tapInstalled = false

  /// Diagnose-Log fuer den Erkennungs-Modus. Bewusst nur ein Bool + Locale-ID
  /// (%{public}@) - kein Audio, kein Transkript, keine PII.
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
      // Gleiche Locale-Logik wie bei "listen": der Aufrufer darf die Sprache
      // mitgeben, ohne Argument bleibt es beim bisherigen Default de_DE.
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
      // Datenschutz: Wenn Apple fuer GENAU DIESE Locale ein On-Device-Modell
      // bereithaelt, bleibt das Audio komplett auf dem Geraet: keine
      // Drittlandsuebermittlung an Apple-Server. Ist das Modell nicht da
      // (Locale ohne On-Device-Support, Asset noch nicht geladen, Simulator,
      // aeltere Hardware), bleibt der Default `false` und die Erkennung laeuft
      // wie bisher server-seitig. NIE hart failen: Fallback ist der Alt-Zustand.
      // `supportsOnDeviceRecognition` ist eine INSTANZ-Property und wird
      // bewusst erst hier gelesen, also nach dem isAvailable-Guard oben.
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
      // F3: `installTap` prueft das Format mit einer C++-Assertion und wirft bei
      // 0 Hz / 0 Kanaelen eine ObjC-NSException ("required condition is false:
      // IsFormatSampleRateAndChannelCountValid(format)"). Das ist ein SIGABRT —
      // das `do/catch` drumherum faengt NUR Swift-Errors und sieht davon nichts,
      // die App stirbt also mitten im Coach-Chat.
      //
      // Ein leeres Format ist kein Sonderfall, sondern der Normalzustand ohne
      // nutzbare Eingaberoute: Mikro von einer anderen App belegt, laufender
      // Anruf, Bluetooth-/CarPlay-Routenwechsel, Simulator. Die Session ist zu
      // diesem Zeitpunkt bereits aktiv (setActive oben), 0 Hz heisst hier also
      // wirklich "keine Route", nicht "noch nicht bereit".
      //
      // `unavailable` ist bewusst gewaehlt: coach_speech.dart:20 matcht genau
      // diesen Code und zeigt "Spracherkennung ist auf diesem Gerät gerade
      // nicht verfügbar." — `recognition_failed` fiele dort in den generischen
      // Zweig (Zeile 25) und wuerde eine technische Meldung durchreichen.
      //
      // Aufraeumen uebernimmt finish -> cleanupAudio: der Tap ist hier noch
      // nicht installiert (tapInstalled == false), die Session wird aber wieder
      // deaktiviert, damit der naechste Versuch eine frische Route bekommt.
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
