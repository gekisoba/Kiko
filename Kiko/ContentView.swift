import SwiftUI

struct ContentView: View {
    @StateObject var authManager = KikoAuthManager.shared
    @StateObject var programManager = KikoProgramManager.shared
    @State var selectedStation: KikoStation?
    @State private var selectedDate = Date()
    @State private var isPresentingCustomRecording = false
    @State private var isPresentingSearch = false
    @State private var isPresentingDownloads = false
    @State private var isShowingDatePicker = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedStation: $selectedStation)
                .navigationTitle("放送局")
        } detail: {
            if let station = selectedStation {
                ProgramListView(station: station)
            } else {
                Text("放送局を選択してください")
                    .foregroundColor(.secondary)
            }
        }
        .task {
            // アプリ起動時に認証と番組表取得を行う
            await authManager.authenticate()
            await programManager.fetchPrograms(date: selectedDate)
        }
        .onChange(of: selectedDate) { _, newDate in
            Task {
                await programManager.fetchPrograms(date: newDate)
            }
        }
        .sheet(isPresented: $isPresentingCustomRecording) {
            CustomRecordingView(initialStationId: selectedStation?.id, authManager: authManager)
        }
        .sheet(isPresented: $isPresentingSearch) {
            SearchProgramsView()
        }
        .sheet(isPresented: $isPresentingDownloads) {
            DownloadsView()
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                if authManager.isAuthenticating {
                    ProgressView()
                        .scaleEffect(0.5)
                        .help("認証中...")
                } else if authManager.isAuthenticated {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .help("認証成功")
                        if let area = authManager.areaId {
                            Text("(\(area))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                        .help("認証失敗")
                }
            }

            ToolbarItem {
                HStack(spacing: 4) {
                    let today = Date()
                    let minDate =
                        Calendar.current.date(byAdding: .day, value: -8, to: today) ?? today

                    Button(action: {
                        let prevDate =
                            Calendar.current.date(byAdding: .day, value: -1, to: selectedDate)
                            ?? selectedDate
                        if prevDate >= minDate {
                            selectedDate = prevDate
                        }
                    }) {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(selectedDate <= minDate)
                    .help("前日")

                    Button("今日") {
                        selectedDate = Date()
                    }
                    .disabled(Calendar.current.isDateInToday(selectedDate))
                    .help("今日へ移動")

                    Button(action: {
                        let nextDate =
                            Calendar.current.date(byAdding: .day, value: 1, to: selectedDate)
                            ?? selectedDate
                        if nextDate <= today {
                            selectedDate = nextDate
                        }
                    }) {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(Calendar.current.isDateInToday(selectedDate))
                    .help("翌日")

                    Button(action: {
                        isShowingDatePicker = true
                    }) {
                        HStack(spacing: 4) {
                            let df = DateFormatter()
                            df.locale = Locale(identifier: "ja_JP")
                            df.dateFormat = "M月d日(E)"
                            Text(df.string(from: selectedDate))
                                .font(.system(.body, design: .monospaced))
                            Image(systemName: "calendar")
                        }
                    }
                    .help("カレンダーから選択")
                    .popover(isPresented: $isShowingDatePicker) {
                        VStack(spacing: 0) {
                            DatePicker(
                                "",
                                selection: $selectedDate,
                                in: minDate...today,
                                displayedComponents: .date
                            )
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .scaleEffect(2.5)
                            .frame(width: 440, height: 440)

                            Divider()

                            Button("今日") {
                                selectedDate = Date()
                                isShowingDatePicker = false
                            }
                            .buttonStyle(.borderless)
                            .font(.headline)
                            .padding(.vertical, 8)
                        }
                        .frame(width: 440, height: 490)
                        .onChange(of: selectedDate) {
                            isShowingDatePicker = false
                        }
                    }
                }
            }

            ToolbarItem(placement: .navigation) {
                Button(action: {
                    Task {
                        await programManager.fetchPrograms(areaId: authManager.areaId)
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("番組表を更新")
            }

            ToolbarItem {
                Button(action: {
                    Task {
                        await programManager.fetchPrograms(date: selectedDate)
                    }
                }) {
                    Label("リフレッシュ", systemImage: "arrow.clockwise")
                }
                .disabled(programManager.isLoading)
            }

            ToolbarItem {
                Button(action: {
                    isPresentingSearch = true
                }) {
                    Label("番組検索", systemImage: "magnifyingglass")
                }
            }

            ToolbarItem {
                Button(action: {
                    isPresentingDownloads = true
                }) {
                    Label("ダウンロード", systemImage: "arrow.down.circle")
                }
            }

            ToolbarItem {
                Button(action: {
                    isPresentingCustomRecording = true
                }) {
                    Label("時間指定録音", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
