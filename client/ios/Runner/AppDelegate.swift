import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var previousBrightness: CGFloat?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "GrupayScreenGuard") else { return }
    let channel = FlutterMethodChannel(name: "grupay/screen_guard", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "display", let arguments = call.arguments as? [String: Bool], let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      UIApplication.shared.isIdleTimerDisabled = arguments["awake"] == true
      if arguments["dimmed"] == true {
        if self.previousBrightness == nil { self.previousBrightness = UIScreen.main.brightness }
        UIScreen.main.brightness = 0
      } else if let brightness = self.previousBrightness {
        UIScreen.main.brightness = brightness
        self.previousBrightness = nil
      }
      result(nil)
    }
    guard let sessionRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "GrupaySession") else { return }
    let session = FlutterMethodChannel(name: "grupay/session", binaryMessenger: sessionRegistrar.messenger())
    session.setMethodCallHandler { call, result in
      guard call.method == "model" else {
        result(FlutterMethodNotImplemented)
        return
      }
      var info = utsname()
      uname(&info)
      result(withUnsafePointer(to: &info.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
      })
    }
  }
}
