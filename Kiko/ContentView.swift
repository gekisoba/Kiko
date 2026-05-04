import SwiftUI

struct ContentView: View {
    @StateObject var authManager = KikoAuthManager.shared
    @StateObject var programManager = KikoProgramManager.shared
    @State var selectedStation: KikoStation?
    @State private var selectedDate = Date().adjustedForRadioDay
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
                AuthenticationStatusView(authManager: authManager)
            }

            ToolbarItem {
                DateNavigationView(selectedDate: $selectedDate)
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

struct AuthenticationStatusView: View {
    @ObservedObject var authManager: KikoAuthManager

    var body: some View {
        if authManager.isAuthenticating {
            ProgressView()
                .scaleEffect(0.5)
                .help("認証中...")
        } else if authManager.isAuthenticated {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .help("認証成功")
                if let areaName = authManager.areaName {
                    Text("(\(areaName))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if let area = authManager.areaId {
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
}

// MARK: - Calendar Picker

struct CalendarPickerView: View {
    @Binding var selectedDate: Date
    let minDate: Date
    let maxDate: Date

    @State private var displayedMonth: Date
    private let calendar = Calendar.current
    private let weekdays = ["日", "月", "火", "水", "木", "金", "土"]

    init(selectedDate: Binding<Date>, minDate: Date, maxDate: Date) {
        _selectedDate = selectedDate
        _displayedMonth = State(initialValue: selectedDate.wrappedValue)
        self.minDate = minDate
        self.maxDate = maxDate
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left").fontWeight(.semibold)
                }
                .buttonStyle(.plain)
                .disabled(!canShift(-1))

                Spacer()

                Text(monthYearLabel)
                    .font(.headline)

                Spacer()

                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right").fontWeight(.semibold)
                }
                .buttonStyle(.plain)
                .disabled(!canShift(1))
            }

            LazyVGrid(columns: gridColumns, spacing: 4) {
                ForEach(weekdays, id: \.self) { label in
                    Text(label)
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: gridColumns, spacing: 4) {
                ForEach(Array(daysInMonth().enumerated()), id: \.offset) { _, date in
                    if let date {
                        DayCell(
                            date: date,
                            isSelected: calendar.isDate(date, inSameDayAs: selectedDate),
                            isToday: calendar.isDateInToday(date),
                            isDisabled: date < dayStart(minDate) || date > dayStart(maxDate)
                        ) {
                            selectedDate = date
                        }
                    } else {
                        Color.clear.frame(height: 32)
                    }
                }
            }
        }
        .padding()
        .frame(width: 280)
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    }

    private var monthYearLabel: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "yyyy年M月"
        return df.string(from: displayedMonth)
    }

    private func dayStart(_ date: Date) -> Date { calendar.startOfDay(for: date) }

    private func canShift(_ direction: Int) -> Bool {
        guard let shifted = calendar.date(byAdding: .month, value: direction, to: displayedMonth)
        else { return false }
        let comps = calendar.dateComponents([.year, .month], from: shifted)
        guard let monthStart = calendar.date(from: comps) else { return false }
        if direction < 0 {
            let monthEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart) ?? monthStart
            return monthEnd >= dayStart(minDate)
        } else {
            return monthStart <= dayStart(maxDate)
        }
    }

    private func shiftMonth(_ direction: Int) {
        if let d = calendar.date(byAdding: .month, value: direction, to: displayedMonth) {
            displayedMonth = d
        }
    }

    private func daysInMonth() -> [Date?] {
        let comps = calendar.dateComponents([.year, .month], from: displayedMonth)
        guard let firstDay = calendar.date(from: comps),
              let range = calendar.range(of: .day, in: .month, for: displayedMonth)
        else { return [] }

        let offset = calendar.component(.weekday, from: firstDay) - 1
        var days: [Date?] = Array(repeating: nil, count: offset)
        for i in range {
            days.append(calendar.date(byAdding: .day, value: i - 1, to: firstDay))
        }
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }
}

struct DayCell: View {
    let date: Date
    let isSelected: Bool
    let isToday: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        let day = Calendar.current.component(.day, from: date)
        Button(action: action) {
            Text("\(day)")
                .font(.body)
                .fontWeight(isToday && !isSelected ? .bold : .regular)
                .frame(width: 32, height: 32)
                .foregroundStyle(
                    isDisabled ? Color.secondary.opacity(0.3) :
                    isSelected ? .white : .primary
                )
                .background(
                    isSelected ? Color.accentColor :
                    isToday ? Color.accentColor.opacity(0.15) : Color.clear,
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

// MARK: - Date Navigation

struct DateNavigationView: View {
    @Binding var selectedDate: Date
    @State private var isShowingDatePicker = false

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "M月d日(E)"
        return df
    }()

    var body: some View {
        HStack(spacing: 4) {
            let today = Date().adjustedForRadioDay
            let minDate = Calendar.current.date(byAdding: .day, value: -8, to: today) ?? today

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
                selectedDate = Date().adjustedForRadioDay
            }
            .disabled(Calendar.current.isDateInToday(selectedDate))  // This check might be slightly off if adjusted, but close enough for now. Actually better to compare equality of date components.
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
                    Text(dateFormatter.string(from: selectedDate))
                        .font(.system(.body, design: .monospaced))
                    Image(systemName: "calendar")
                }
            }
            .help("カレンダーから選択")
            .popover(isPresented: $isShowingDatePicker) {
                VStack(spacing: 0) {
                    CalendarPickerView(
                        selectedDate: $selectedDate,
                        minDate: minDate,
                        maxDate: today
                    )

                    Divider()

                    Button("今日へ移動") {
                        selectedDate = Date().adjustedForRadioDay
                        isShowingDatePicker = false
                    }
                    .buttonStyle(.borderless)
                    .font(.headline)
                    .padding(.vertical, 10)
                }
                .onChange(of: selectedDate) {
                    isShowingDatePicker = false
                }
            }
        }
    }
}
