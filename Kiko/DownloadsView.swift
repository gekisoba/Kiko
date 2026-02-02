import SwiftUI

struct DownloadsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var ffmpegRunner = FFmpegRunner.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Debug / System Status
                    VStack(alignment: .leading, spacing: 8) {
                        Text("システム状態").font(.headline).foregroundColor(.secondary)
                        HStack {
                            Text("状態:")
                            Text(
                                ffmpegRunner.isRecording
                                    ? "ダウンロード中 (\(ffmpegRunner.activeDownloads.count))" : "待機中"
                            )
                            .font(.title3).bold()
                            .foregroundColor(ffmpegRunner.isRecording ? .red : .gray)
                            Spacer()
                        }
                        // Instance check removed to simplify type inference
                        Divider()
                    }

                    // Active Recording
                    if !ffmpegRunner.activeDownloads.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("ダウンロード中 (\(ffmpegRunner.activeDownloads.count)件)").font(.headline)
                                .foregroundColor(.accentColor)

                            ForEach(ffmpegRunner.activeDownloads) { download in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(download.title)
                                            .font(.subheadline).bold()
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    ProgressView(value: download.progress, total: 1.0)
                                        .frame(width: 100)
                                    Text("\(Int(download.progress * 100))%")
                                        .font(.caption)
                                        .frame(width: 35, alignment: .trailing)

                                    Button(action: {
                                        ffmpegRunner.cancelDownload(id: download.id)
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.gray)
                                    }
                                    .buttonStyle(.plain)
                                    .help("キャンセル")
                                }
                                .padding(.vertical, 2)
                            }

                            if ffmpegRunner.isProcessingQueue {
                                Text("キュー処理中... (並列数: 3)").font(.caption).foregroundColor(
                                    .secondary)
                            }
                            Divider()
                        }
                    }

                    // Current Batch
                    if let batch = ffmpegRunner.currentProcessingBatch {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("処理中のグループ (残り: \(batch.programs.count)件)").font(.headline)
                            ForEach(batch.programs) { program in
                                HStack {
                                    Text(program.title)
                                        .foregroundColor(
                                            program.title == ffmpegRunner.currentRecordingTitle
                                                ? .accentColor : .primary)
                                    Spacer()
                                    if program.title == ffmpegRunner.currentRecordingTitle {
                                        Text("進行中").font(.caption).foregroundColor(.accentColor)
                                    } else {
                                        Text("待機中").font(.caption).foregroundColor(.gray)
                                    }
                                }
                            }
                            Divider()
                        }
                    }

                    // Queue
                    if !ffmpegRunner.requestQueue.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("待機中 (キュー: \(ffmpegRunner.requestQueue.count)件)").font(
                                .headline)
                            ForEach(ffmpegRunner.requestQueue) { request in
                                VStack(alignment: .leading) {
                                    if request.mergeByDate {
                                        Text("【結合】\(request.programs.first?.title ?? "複数の番組")")
                                            .bold()
                                        Text("他 \(request.programs.count - 1) 件").font(.caption)
                                            .foregroundColor(.gray)
                                    } else {
                                        ForEach(request.programs) { program in
                                            Text(program.title)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .onDelete { indexSet in
                                ffmpegRunner.deleteRequest(at: indexSet)
                            }
                            Divider()
                        }
                    }

                    // History
                    if !ffmpegRunner.downloadHistory.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("履歴").font(.headline)
                            ForEach(ffmpegRunner.downloadHistory) { item in
                                VStack(alignment: .leading) {
                                    Text(item.title).font(.body)
                                    HStack {
                                        Text(item.status)
                                            .font(.caption).bold()
                                            .foregroundColor(
                                                item.status.contains("完了") ? .green : .red)
                                        Spacer()
                                        Text(item.date, style: .time).font(.caption)
                                            .foregroundColor(.gray)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            Divider()
                        }
                    }

                    // Empty State
                    if !ffmpegRunner.isRecording && ffmpegRunner.requestQueue.isEmpty
                        && ffmpegRunner.currentProcessingBatch == nil
                        && ffmpegRunner.downloadHistory.isEmpty
                    {
                        Text("履歴および待機中の項目はありません")
                            .foregroundColor(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding()
            }
            .navigationTitle("ダウンロード管理")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }

    }
}
