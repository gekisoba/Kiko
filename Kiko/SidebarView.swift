import SwiftUI

struct SidebarView: View {
    @ObservedObject var programManager = KikoProgramManager.shared
    @Binding var selectedStation: KikoStation?
    @ObservedObject var authManager = KikoAuthManager.shared
    @State private var isShowingLogin = false

    var body: some View {
        List(selection: $selectedStation) {
            Section("エリア") {
                Picker(
                    "地域選択",
                    selection: Binding(
                        get: { programManager.currentAreaId },
                        set: { (newArea: String) in
                            Task {
                                await programManager.fetchPrograms(areaId: newArea)
                            }
                        }
                    )
                ) {
                    Text("自動 (現在地)").tag(KikoAuthManager.shared.areaId ?? "JP13")
                    Text("東京").tag("JP13")
                    Text("大阪").tag("JP27")
                    Text("名古屋").tag("JP23")
                    Text("福岡").tag("JP40")
                }
                .labelsHidden()
            }

            Section("放送局") {
                ForEach(programManager.stations) { station in
                    NavigationLink(value: station) {
                        HStack {
                            Image(systemName: "radio")
                            Text(station.name)
                        }
                    }
                }
            }

            Section("プレミアム設定") {
                if authManager.isPremium {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.gold)
                        Text("プレミアムプラン")
                    }
                } else {
                    Text("エリアフリーを利用するには設定からログインしてください")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

extension Color {
    static let gold = Color(red: 1.0, green: 0.84, blue: 0.0)
}
