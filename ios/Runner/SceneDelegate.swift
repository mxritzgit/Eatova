import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    let forwardedURLs = Set(RecipeShareWake.route(URLContexts.map(\.url)) {
      NotificationCenter.default.post(name: RecipeShareWake.notification, object: nil)
    })
    let forwarded = URLContexts.filter { forwardedURLs.contains($0.url) }
    if !forwarded.isEmpty {
      super.scene(scene, openURLContexts: forwarded)
    }
  }

  // Cold launches keep Flutter's scene bootstrap. The owner-bound receiver drains
  // the inbox at startup; EatovaApp consumes Flutter's later navigation echo.
}
