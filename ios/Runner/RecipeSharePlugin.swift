import Flutter
import Foundation

final class RecipeSharePlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "eatova/recipe_share", binaryMessenger: registrar.messenger())
    let instance = RecipeSharePlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.publish(instance)
  }

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(sharesAvailable(_:)),
      name: RecipeShareWake.notification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func sharesAvailable(_ notification: Notification) {
    channel.invokeMethod("sharesAvailable", arguments: nil)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "consumePending" || call.method == "clearPending" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let arguments = call.arguments as? [String: Any], arguments.keys.contains("owner"),
      arguments["owner"] is NSNull || arguments["owner"] is String else {
      result(FlutterError(code: "invalid_share_owner", message: "The share owner is invalid.", details: nil))
      return
    }
    let owner = arguments["owner"] as? String
    guard RecipeShareInbox.validOwner(owner) else {
      result(FlutterError(code: "invalid_share_owner", message: "The share owner is invalid.", details: nil))
      return
    }
    do {
      let inbox = try RecipeShareInbox.shared()
      if call.method == "consumePending" {
        result(try inbox.consume(expectedOwner: owner))
      } else {
        try inbox.clear(expectedOwner: owner)
        result(nil)
      }
    } catch {
      result(FlutterError(code: "share_inbox_unavailable", message: "The share inbox is unavailable.", details: nil))
    }
  }
}
