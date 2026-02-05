import SwiftUI

struct ProgramListView: View {
    let station: KikoStation
    @ObservedObject var programManager = KikoProgramManager.shared
    @ObservedObject var authManager = KikoAuthManager.shared
    @ObservedObject var ffmpegRunner = FFmpegRunner.shared

    var body: some View {
        List(programManager.programs[station.id] ?? []) { program in
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    if let imageUrl = program.imageUrl, let url = URL(string: imageUrl) {
                        AsyncImage(url: url) { image in
                            image.resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color.gray.opacity(0.3)
                        }
                        .frame(width: 80, height: 45)  // Radiko images are usually 16:9 like
                        .cornerRadius(4)
                    }

                    VStack(alignment: .leading) {
                        Text(program.title)
                            .font(.headline)
                        Text(program.durationFormatted)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if let active = ffmpegRunner.activeDownloads.first(where: {
                        $0.programId == program.id
                    }) {
                        VStack(alignment: .trailing, spacing: 2) {
                            ProgressView(value: active.progress, total: 1.0)
                                .progressViewStyle(.linear)
                                .frame(width: 60)
                            Text("\(Int(active.progress * 100))%")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Button(action: {
                            Task {
                                if let token = authManager.authToken {
                                    await ffmpegRunner.startRecording(
                                        program: program, authToken: token)
                                }
                            }
                        }) {
                            Label("録音", systemImage: "record.circle")
                        }
                        .disabled(ffmpegRunner.isRecording || !authManager.isAuthenticated)
                    }
                }

                Text(program.description)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle(station.name)
    }
}
