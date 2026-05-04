import SwiftUI

struct SearchProgramsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var programManager = KikoProgramManager.shared
    @ObservedObject var ffmpegRunner = FFmpegRunner.shared
    @ObservedObject var authManager = KikoAuthManager.shared

    @State private var keyword: String = ""
    @State private var searchResult: [KikoProgram] = []
    @State private var selectedPrograms: Set<String> = []
    @State private var isSearching = false
    @State private var shouldMerge = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("番組検索 & 一括ダウンロード")
                    .font(.headline)

                HStack {
                    TextField("番組名キーワード (例: ニュース)", text: $keyword)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            performSearch()
                        }

                    Button(action: performSearch) {
                        Label("検索 (過去1週間)", systemImage: "magnifyingglass")
                    }
                    .disabled(keyword.isEmpty || isSearching)
                }
                .padding(.horizontal)

                if isSearching {
                    ProgressView("検索中...")
                }

                List {
                    ForEach(searchResult) { program in
                        HStack {
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { selectedPrograms.contains(program.id) },
                                    set: { isSelected in
                                        if isSelected {
                                            selectedPrograms.insert(program.id)
                                        } else {
                                            selectedPrograms.remove(program.id)
                                        }
                                    }
                                )
                            )
                            .labelsHidden()

                            VStack(alignment: .leading) {
                                Text(program.title)
                                    .font(.headline)
                                Text(
                                    "\(formattedDate(program.startTime)) \(program.durationFormatted)"
                                )
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }

                            Spacer()

                            Text(program.stationId)
                                .font(.caption2)
                                .padding(4)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }
                }
                .overlay {
                    if searchResult.isEmpty && !isSearching {
                        Text("検索結果なし")
                            .foregroundColor(.secondary)
                    }
                }

                VStack(spacing: 12) {
                    Toggle("日付ごとに詳しく結合する (前半・後半などを1つに)", isOn: $shouldMerge)
                        .font(.caption)

                    Button(action: startBulkDownload) {
                        Text("選択した \(selectedPrograms.count) 件をダウンロード")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedPrograms.isEmpty)
                }
                .padding()
            }
            .frame(minWidth: 500, minHeight: 600)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func performSearch() {
        guard !keyword.isEmpty else { return }
        isSearching = true
        searchResult = []
        selectedPrograms = []

        Task {
            let results = await programManager.searchPrograms(keyword: keyword)
            await MainActor.run {
                self.searchResult = results.sorted { $0.startTime < $1.startTime }
                self.selectedPrograms = Set(self.searchResult.map { $0.id })
                self.isSearching = false
            }
        }
    }

    private func startBulkDownload() {
        let targets = searchResult.filter { selectedPrograms.contains($0.id) }

        guard !targets.isEmpty else { return }

        guard let token = authManager.authToken else { return }

        Task {
            // Ensure UI feedback
            await ffmpegRunner.addToQueue(
                programs: targets, mergeByDate: shouldMerge, authToken: token)
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "M/d(E)"
        return df.string(from: date)
    }
}
