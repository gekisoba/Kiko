import SwiftUI

struct SettingsView: View {
    private enum Tabs: Hashable {
        case general, account
    }

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("一般", systemImage: "gear")
                }
                .tag(Tabs.general)

            AccountSettingsView()
                .tabItem {
                    Label("アカウント", systemImage: "person.crop.circle")
                }
                .tag(Tabs.account)
        }
        .padding(20)
        .frame(width: 450)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var ffmpeg = FFmpegRunner.shared

    var body: some View {
        Form {
            Section(header: Text("ダウンロード")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ダウンロード先:")
                        .font(.subheadline)

                    HStack {
                        Text(ffmpeg.downloadPath)
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(4)

                        Button("変更...") {
                            selectFolder()
                        }
                    }
                }
            }
        }
        .padding()
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: ffmpeg.downloadPath)

        if panel.runModal() == .OK {
            if let url = panel.url {
                ffmpeg.downloadPath = url.path
            }
        }
    }
}

struct AccountSettingsView: View {
    @ObservedObject var authManager = KikoAuthManager.shared
    @State private var email = ""
    @State private var password = ""
    @State private var isLoggingIn = false
    @State private var errorMessage: String? = nil

    var body: some View {
        Form {
            Section(header: Text("Radiko プレミアム")) {
                if authManager.isAuthenticated {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "person.circle.fill")
                                .font(.title)
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading) {
                                Text(authManager.email)
                                    .font(.headline)
                                if authManager.isPremium {
                                    Text("プレミアム会員")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            }
                        }

                        Button("ログアウト") {
                            logout()
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("メールアドレス", text: $email)
                            .textFieldStyle(RoundedBorderTextFieldStyle())

                        SecureField("パスワード", text: $password)
                            .textFieldStyle(RoundedBorderTextFieldStyle())

                        if let error = errorMessage {
                            Text(error)
                                .foregroundColor(.red)
                                .font(.caption)
                        }

                        HStack {
                            Button("ログイン") {
                                performLogin()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isLoggingIn || email.isEmpty || password.isEmpty)

                            if isLoggingIn {
                                ProgressView()
                                    .scaleEffect(0.5)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .onAppear {
            email = authManager.email
            password = authManager.password
        }
    }

    private func performLogin() {
        isLoggingIn = true
        errorMessage = nil

        Task {
            authManager.email = email
            authManager.password = password

            do {
                try await authManager.login()
                await authManager.authenticate()
                if !authManager.isAuthenticated {
                    if let lastErr = authManager.lastError {
                        errorMessage = "ログイン失敗: \(lastErr.localizedDescription)"
                    } else {
                        errorMessage = "ログインに失敗しました。"
                    }
                }
            } catch {
                errorMessage = "エラーが発生しました: \(error.localizedDescription)"
            }
            isLoggingIn = false
        }
    }

    private func logout() {
        authManager.isAuthenticated = false
        authManager.authToken = nil
        authManager.sessionCookie = nil
        // UserDefaultsからも削除する場合はここに追加
    }
}
