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

// MARK: - Date Extensions
extension Date {
    /// Returns the "Radio Day" adjusted date.
    /// If the time is before 5:00 AM, it is treated as the previous calendar day.
    var adjustedForRadioDay: Date {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: self)
        if hour < 5 {
            return calendar.date(byAdding: .day, value: -1, to: self) ?? self
        }
        return self
    }
}
