import SwiftUI

struct LoginView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var authManager = KikoAuthManager.shared

    @State private var email = ""
    @State private var password = ""
    @State private var isLoggingIn = false
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(spacing: 20) {
            Text("Kiko プレミアムログイン")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                Text("メールアドレス")
                TextField("email@example.com", text: $email)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                Text("パスワード")
                SecureField("password", text: $password)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .padding()

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            HStack {
                Button("キャンセル") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("ログイン") {
                    performLogin()
                }
                .buttonStyle(.borderedProminent)
                .disabled(email.isEmpty || password.isEmpty || isLoggingIn)
            }

            if isLoggingIn {
                ProgressView()
            }
        }
        .padding()
        .frame(width: 350, height: 300)
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
                await authManager.authenticate()  // Refresh auth token with session
                dismiss()
            } catch {
                errorMessage = "ログインに失敗しました。メールアドレスとパスワードを確認してください。"
            }
            isLoggingIn = false
        }
    }
}
