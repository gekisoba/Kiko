import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 通常のアプリとしてアクティベーションポリシーを設定
        NSApp.setActivationPolicy(.regular)
        // アプリ起動時にウィンドウを最前面にする
        NSApp.activate(ignoringOtherApps: true)
        // メインウィンドウをフォーカス
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@main
struct KikoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1000, height: 700)

        Settings {
            SettingsView()
        }
    }
}
