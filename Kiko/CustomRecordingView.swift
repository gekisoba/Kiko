import SwiftUI

struct CustomRecordingView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var programManager = KikoProgramManager.shared
    @ObservedObject var authManager: KikoAuthManager  // Dependency injection
    @ObservedObject var ffmpegRunner = FFmpegRunner.shared

    @State var selectedStationId: String
    @State var startTime: Date
    @State var endTime: Date
    @State var title: String = ""
    @State var repeatDays: Int = 1

    // Initializer to set defaults
    init(initialStationId: String?, authManager: KikoAuthManager) {
        self.authManager = authManager
        _selectedStationId = State(initialValue: initialStationId ?? "TBS")
        // Default to current time and +1 hour
        let now = Date()
        _startTime = State(initialValue: now)
        _endTime = State(initialValue: now.addingTimeInterval(3600))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("任意時間録音")
                    .font(.headline)

                Form {
                    Picker("放送局", selection: $selectedStationId) {
                        ForEach(programManager.stations) { station in
                            Text(station.name).tag(station.id)
                        }
                    }

                    TextField("タイトル (任意)", text: $title)

                    DatePicker("開始日時", selection: $startTime)
                    DatePicker("終了日時", selection: $endTime)

                    Stepper(value: $repeatDays, in: 1...7) {
                        Text("繰り返し: \(repeatDays)日分")
                    }
                }
                .padding()
                .onChange(of: selectedStationId) { _, _ in attemptAutoFill() }
                .onChange(of: startTime) { _, _ in attemptAutoFill() }
                .onChange(of: endTime) { _, _ in attemptAutoFill() }

                HStack {
                    Button("キャンセル") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("録音開始") {
                        Task {
                            let recordingTitle = title.isEmpty ? "カスタム録音" : title
                            guard let token = authManager.authToken else { return }

                            let days = repeatDays
                            let sId = selectedStationId
                            let start = startTime
                            let end = endTime

                            // Use runner on MainActor logic or await
                            let runner = ffmpegRunner

                            // Create Program Objects manually
                            var programs: [KikoProgram] = []
                            for i in 0..<days {
                                let dayOffset = TimeInterval(i * 24 * 60 * 60)
                                let currentStart = start.addingTimeInterval(dayOffset)
                                let currentEnd = end.addingTimeInterval(dayOffset)
                                let currentTitle =
                                    days > 1 ? "\(recordingTitle) (\(i+1))" : recordingTitle

                                // Use currentStart directly without padding
                                // let bufferedStart = currentStart.addingTimeInterval(-60)

                                // Create a dummy KikoProgram for the custom recording
                                let program = KikoProgram(
                                    id: "custom_\(UUID().uuidString)",
                                    title: currentTitle,
                                    description: "任意時間録音",
                                    startTime: currentStart,
                                    endTime: currentEnd,
                                    stationId: sId,
                                    performers: "",
                                    imageUrl: nil
                                )
                                programs.append(program)
                            }

                            await runner.addToQueue(
                                programs: programs, mergeByDate: false, authToken: token)

                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(authManager.authToken == nil)
                }

                if authManager.authToken == nil {
                    HStack {
                        Text("認証未完了")
                            .foregroundColor(.red)
                        Button("再試行") {
                            Task {
                                await authManager.authenticate()
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.caption)
                }
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 450, height: 450)  // Increased height slightly for Toolbar
    }

    private func attemptAutoFill() {
        guard title.isEmpty else { return }  // Don't overwrite if user typed something

        // Simple search in loaded programs
        // NOTE: This only works if the program is already loaded (i.e. same day as selected in main view)
        // For more robust behavior, we'd need to async fetch.
        if let programs = programManager.programs[selectedStationId] {
            // Find program that contains startTime
            if let match = programs.first(where: {
                $0.startTime <= startTime && $0.endTime > startTime
            }) {
                title = match.title
            }
        }
    }
}
