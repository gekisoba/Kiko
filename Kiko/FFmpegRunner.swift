import Combine
import SwiftUI

@MainActor
class FFmpegRunner: NSObject, ObservableObject {

    static let shared = FFmpegRunner()

    @Published var isRecording = false
    @Published var recordingProgress: Double = 0.0
    @Published var currentRecordingTitle: String? = nil

    @Published var activeDownloads: [ActiveDownload] = []
    private var activeProcesses: [UUID: Process] = [:]
    private let maxConcurrent = 3

    private let ffmpegPath = "/opt/homebrew/bin/ffmpeg"
    private let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    @Published var downloadPath: String {
        didSet {
            UserDefaults.standard.set(downloadPath, forKey: "download_path")
        }
    }

    override private init() {
        self.downloadPath =
            UserDefaults.standard.string(forKey: "download_path")
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
    }

    @Published var requestQueue: [DownloadRequest] = []
    @Published var currentProcessingBatch: DownloadRequest? = nil
    @Published var isProcessingQueue = false
    @Published var downloadHistory: [DownloadHistoryItem] = []

    struct ActiveDownload: Identifiable {
        let id: UUID
        let programId: String
        let title: String
        var progress: Double
    }

    struct DownloadRequest: Identifiable {
        let id = UUID()
        let programs: [KikoProgram]
        let mergeByDate: Bool
        let authToken: String
    }

    struct DownloadHistoryItem: Identifiable {
        let id = UUID()
        let title: String
        let date: Date
        let status: String  // "Success", "Failed (Code: X)"
        let path: String
    }

    // Original startRecording (now just a convenience wrapper or deprecated? kept for direct calls)
    func startRecording(program: KikoProgram, authToken: String) async {
        // Direct recording without queue (or add to queue as single item)
        await addToQueue(programs: [program], mergeByDate: false, authToken: authToken)
    }

    func addToQueue(programs: [KikoProgram], mergeByDate: Bool, authToken: String) async {
        let request = DownloadRequest(
            programs: programs, mergeByDate: mergeByDate, authToken: authToken)
        requestQueue.append(request)
        if !isProcessingQueue {
            await processQueue()
        }
    }

    func cancelDownload(id: UUID) {
        if let process = activeProcesses[id] {
            print("Cancelling download: \(id)")
            process.terminate()
        }
    }

    func deleteRequest(at offsets: IndexSet) {
        requestQueue.remove(atOffsets: offsets)
    }

    private func processQueue() async {
        isProcessingQueue = true
        while !requestQueue.isEmpty {
            let request = requestQueue.removeFirst()
            self.currentProcessingBatch = request

            if request.mergeByDate {
                let grouped = Dictionary(grouping: request.programs) { program -> String in
                    let df = DateFormatter()
                    df.dateFormat = "yyyyMMdd"
                    return df.string(from: program.startTime)
                }

                for (dateKey, daysPrograms) in grouped {
                    let sortedPrograms = daysPrograms.sorted { $0.startTime < $1.startTime }
                    var downloadedResults: [(Int, String)] = []

                    await withTaskGroup(of: (Int, String)?.self) { group in
                        var running = 0
                        for (index, program) in sortedPrograms.enumerated() {
                            if running >= maxConcurrent {
                                if let res = await group.next() {
                                    if let r = res { downloadedResults.append(r) }
                                }
                                running -= 1
                            }

                            // Calculate Path on Main Actor (Fix for Actor Isolation Error)
                            let fileName = self.getFileName(program: program)
                            let path = (self.downloadPath as NSString).appendingPathComponent(
                                fileName)

                            running += 1
                            group.addTask {
                                await self.startRecordingInternal(
                                    program: program, authToken: request.authToken)
                                return (index, path)
                            }
                        }

                        // Collect remaining
                        for await res in group {
                            if let r = res { downloadedResults.append(r) }
                        }
                    }

                    // Sort and Extract Paths
                    let filePaths = downloadedResults.sorted { $0.0 < $1.0 }.map { $0.1 }

                    if !filePaths.isEmpty {
                        await mergeFiles(
                            filePaths: filePaths, dateKey: dateKey,
                            title: sortedPrograms.first?.title ?? "Merged")
                    }
                }
            } else {
                // Parallel Bulk Download
                await withTaskGroup(of: Void.self) { group in
                    var running = 0
                    for program in request.programs {
                        if running >= maxConcurrent {
                            await group.next()
                            running -= 1
                        }

                        running += 1
                        group.addTask {
                            await self.startRecordingInternal(
                                program: program, authToken: request.authToken)
                        }
                    }
                }
            }

            self.currentProcessingBatch = nil
        }
        isProcessingQueue = false
    }

    private func generateFileName(stationId: String, startTime: Date, title: String) -> String {
        let dfDate = DateFormatter()
        dfDate.dateFormat = "yyyyMMdd"
        let dateStr = dfDate.string(from: startTime)
        let safeTitle = title.replacingOccurrences(of: "/", with: "_")
        let stationName =
            KikoProgramManager.shared.stations.first(where: { $0.id == stationId })?.name
            ?? stationId
        return "[\(dateStr)]_\(stationName)_\(safeTitle).m4a"
    }

    private func getFileName(program: KikoProgram) -> String {
        return generateFileName(
            stationId: program.stationId, startTime: program.startTime, title: program.title)
    }

    private func mergeFiles(filePaths: [String], dateKey: String, title: String) async {
        guard filePaths.count > 1 else { return }  // No need to merge single file

        let fileManager = FileManager.default
        let listFileUrl = fileManager.temporaryDirectory.appendingPathComponent(
            "merge_list_\(UUID()).txt")
        let outputFileName =
            "[\(dateKey)]_\(title.replacingOccurrences(of: "/", with: "_"))_merged.m4a"
        let outputPath = (self.downloadPath as NSString).appendingPathComponent(outputFileName)

        var listContent = ""
        for path in filePaths {
            listContent += "file '\(path)'\n"
        }

        do {
            try listContent.write(to: listFileUrl, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = [
                "-f", "concat",
                "-safe", "0",
                "-i", listFileUrl.path,
                "-c", "copy",
                "-y",
                outputPath,
            ]

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                print("Merge success: \(outputPath)")
                // Delete originals
                for path in filePaths {
                    try? fileManager.removeItem(atPath: path)
                }
            } else {
                print("Merge failed")
            }

            try? fileManager.removeItem(at: listFileUrl)  // Cleanup list

        } catch {
            print("Merge error: \(error)")
        }
    }

    // Renamed original startRecording to internal and updated signature if needed
    func startRecordingInternal(program: KikoProgram, authToken: String) async {
        let areaId =
            KikoProgramManager.shared.stations.first(where: { $0.id == program.stationId })?
            .areaId
            ?? KikoAuthManager.shared.areaId ?? "JP13"
        await startRecording(
            stationId: program.stationId,
            startTime: program.startTime,
            endTime: program.endTime,
            title: program.title,
            authToken: authToken,
            areaId: areaId,
            programId: program.id,
            imageUrl: program.imageUrl
        )
    }

    // Updated startRecording for Parallel execution AND Segment Parallelism
    func startRecording(
        stationId: String, startTime: Date, endTime: Date, title: String, authToken: String,
        areaId: String, programId: String? = nil, imageUrl: String? = nil
    ) async {
        let downloadID = UUID()
        let newDownload = ActiveDownload(
            id: downloadID, programId: programId ?? stationId, title: title, progress: 0.0)

        await MainActor.run {
            self.activeDownloads.append(newDownload)
            self.isRecording = true
            self.currentRecordingTitle = title
        }

        defer {
            Task { @MainActor in
                if let index = self.activeDownloads.firstIndex(where: { $0.id == downloadID }) {
                    self.activeDownloads.remove(at: index)
                }
                self.isRecording = !self.activeDownloads.isEmpty
                if !self.isRecording {
                    self.currentRecordingTitle = nil
                    self.recordingProgress = 0.0
                }
                self.activeProcesses.removeValue(forKey: downloadID)
            }
        }

        let df = DateFormatter()
        df.dateFormat = "yyyyMMddHHmmss"
        let ft = df.string(from: startTime)
        let to = df.string(from: endTime)

        var currentAuthToken = authToken
        var retryCount = 0
        let maxRetries = 1

        while true {
            do {
                let duration = Int(endTime.timeIntervalSince(startTime))
                if let result = try await fetchStreamURL(
                    stationId: stationId, ft: ft, to: to, duration: duration,
                    authToken: currentAuthToken,
                    areaId: areaId, length: 60)
                {
                    // REPLACEMENT: Use Parallel Segment Downloading
                    await startRecordingParallel(
                        stationId: stationId, startTime: startTime, endTime: endTime,
                        title: title, authToken: currentAuthToken, areaId: areaId,
                        downloadID: downloadID,
                        result: (
                            url: result.url, cookies: result.cookies, content: result.content,
                            baseURL: result.baseURL
                        ),
                        imageUrl: imageUrl
                    )
                    break  // Success

                } else {
                    // Failed to fetch (likely 403 or nil response)
                    if retryCount < maxRetries {
                        print(
                            "Fetch failed (possibly 403). Attempting re-authentication and retry..."
                        )
                        await KikoAuthManager.shared.authenticate(forceRefresh: true)
                        if KikoAuthManager.shared.isAuthenticated,
                            let newToken = KikoAuthManager.shared.authToken
                        {
                            print("Re-authentication successful. Retrying with new token.")
                            currentAuthToken = newToken
                            retryCount += 1
                            continue
                        } else {
                            print("Re-authentication failed.")
                        }
                    }

                    print("Failed to fetch stream URL content after retries")
                    Task { @MainActor in
                        let item = DownloadHistoryItem(
                            title: title, date: Date(), status: "URL取得失敗", path: "")
                        self.downloadHistory.insert(item, at: 0)
                    }
                    break
                }
            } catch {
                if retryCount < maxRetries {
                    print("Error during fetch: \(error). Attempting re-authentication and retry...")
                    await KikoAuthManager.shared.authenticate(forceRefresh: true)
                    if KikoAuthManager.shared.isAuthenticated,
                        let newToken = KikoAuthManager.shared.authToken
                    {
                        print("Re-authentication successful. Retrying with new token.")
                        currentAuthToken = newToken
                        retryCount += 1
                        continue
                    }
                }

                print("Error during recording process: \(error)")
                Task { @MainActor in
                    let item = DownloadHistoryItem(
                        title: title, date: Date(), status: "エラー: \(error.localizedDescription)",
                        path: "")
                    self.downloadHistory.insert(item, at: 0)
                }
                break
            }
        }
    }

    private func fetchStreamURL(
        stationId: String, ft: String, to: String, duration: Int, authToken: String, areaId: String,
        seekOffset: Int = 0, length: Int? = nil, forcedBaseURL: String? = nil
    )
        async throws -> (url: String, cookies: String?, content: String, baseURL: String)?
    {
        let targetLength = length ?? duration
        var validBaseURL = ""

        // Use the authenticated user's areaId for the request headers to support Area-free
        let requestAreaId = KikoAuthManager.shared.areaId ?? areaId

        if let fb = forcedBaseURL {
            validBaseURL = fb
        } else {
            // 1. Fetch the station stream configuration XML to get the correct playlist base URL
            let configURLString = "https://radiko.jp/v3/station/stream/pc_html5/\(stationId).xml"

            guard let configURL = URL(string: configURLString) else { return nil }
            var configRequest = URLRequest(url: configURL)
            configRequest.setValue(authToken, forHTTPHeaderField: "X-Radiko-AuthToken")
            configRequest.setValue(requestAreaId, forHTTPHeaderField: "X-Radiko-AreaId")
            configRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            if let session = KikoAuthManager.shared.sessionCookie {
                configRequest.setValue(session, forHTTPHeaderField: "Cookie")
            }

            let (configData, _) = try await URLSession.shared.data(for: configRequest)
            guard let configContent = String(data: configData, encoding: .utf8) else { return nil }

            if let timeFreeRange = configContent.range(of: "timefree=\"1\"") {
                let afterTimeFree = configContent[timeFreeRange.upperBound...]
                if let startTag = afterTimeFree.range(of: "<playlist_create_url>"),
                    let endTag = afterTimeFree.range(of: "</playlist_create_url>")
                {
                    validBaseURL = String(afterTimeFree[startTag.upperBound..<endTag.lowerBound])
                }
            }
        }

        guard !validBaseURL.isEmpty else { return nil }

        print("Base Playlist URL found: \(validBaseURL)")

        // 3. Generate lsid (32 random hex characters)
        let lsid = (0..<32).map { _ in String(format: "%01x", Int.random(in: 0...15)) }.joined()

        // Adjust seek time based on offset
        var seekTime = ft
        if seekOffset > 0 {
            let df = DateFormatter()
            df.dateFormat = "yyyyMMddHHmmss"
            if let baseDate = df.date(from: ft) {
                seekTime = df.string(from: baseDate.addingTimeInterval(TimeInterval(seekOffset)))
            }
        }

        let playlistURL =
            "\(validBaseURL)?station_id=\(stationId)&start_at=\(ft)&ft=\(ft)&seek=\(seekTime)&l=\(targetLength)&lsid=\(lsid)&type=b&preroll=0"

        print("Fetching Stream URL: \(playlistURL)")

        var request = URLRequest(url: URL(string: playlistURL)!)

        if let session = KikoAuthManager.shared.sessionCookie {
            request.setValue(session, forHTTPHeaderField: "Cookie")
        }

        request.setValue(authToken, forHTTPHeaderField: "X-Radiko-AuthToken")
        request.setValue(requestAreaId, forHTTPHeaderField: "X-Radiko-AreaId")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        // Add consistency headers just in case
        request.setValue("pc_html5", forHTTPHeaderField: "X-Radiko-App")
        request.setValue("0.0.1", forHTTPHeaderField: "X-Radiko-App-Version")
        request.setValue("pc", forHTTPHeaderField: "X-Radiko-Device")
        request.setValue("dummy_user", forHTTPHeaderField: "X-Radiko-User")
        request.setValue("pc_html5_key", forHTTPHeaderField: "X-Radiko-App-Key")

        let (data, response) = try await URLSession.shared.data(for: request)

        var cookieString: String? = nil
        let httpResponse = response as? HTTPURLResponse
        let status = httpResponse?.statusCode ?? 0
        print("Response Status: \(status)")

        if let httpResponse = httpResponse {
            // Extract Cookies from header fields
            if let cookies = httpResponse.allHeaderFields["Set-Cookie"] as? String {
                cookieString = cookies
            } else if let url = httpResponse.url {
                // Fallback: check shared storage
                let cookies = HTTPCookieStorage.shared.cookies(for: url)
                let cookiesHeader = HTTPCookie.requestHeaderFields(with: cookies ?? [])
                if let c = cookiesHeader["Cookie"] {
                    cookieString = c
                }
            }
        }

        guard status == 200 else {
            print("Failed to fetch playlist: \(status)")
            if let body = String(data: data, encoding: .utf8) {
                print("Error Body: \(body)")
            }
            return nil
        }

        if let content = String(data: data, encoding: .utf8) {
            if content.contains("<html") || content.contains("error") {
                print("Response Body: \(content)")
            }

            // Parse Master Playlist to find the Media Playlist URL (usually medialist)
            // Look for the first loop line that is not a comment
            let lines = content.components(separatedBy: "\n")
            if let mediaPlaylistLine = lines.first(where: { !$0.hasPrefix("#") && !$0.isEmpty }) {
                var finalMediaURL = mediaPlaylistLine.trimmingCharacters(
                    in: .whitespacesAndNewlines)

                // Handle relative URL
                if !finalMediaURL.hasPrefix("http") {
                    if let baseURL = response.url?.deletingLastPathComponent() {
                        finalMediaURL = baseURL.appendingPathComponent(finalMediaURL).absoluteString
                    }
                }

                print("Resolved Media Playlist URL: \(finalMediaURL)")

                var mediaReq = URLRequest(url: URL(string: finalMediaURL)!)
                mediaReq.setValue(authToken, forHTTPHeaderField: "X-Radiko-AuthToken")
                mediaReq.setValue("pc_html5", forHTTPHeaderField: "X-Radiko-App")
                mediaReq.setValue("0.0.1", forHTTPHeaderField: "X-Radiko-App-Version")
                mediaReq.setValue("pc", forHTTPHeaderField: "X-Radiko-Device")
                mediaReq.setValue("dummy_user", forHTTPHeaderField: "X-Radiko-User")
                mediaReq.setValue("pc_html5_key", forHTTPHeaderField: "X-Radiko-App-Key")
                mediaReq.setValue(requestAreaId, forHTTPHeaderField: "X-Radiko-AreaId")
                mediaReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                mediaReq.setValue("https://radiko.jp", forHTTPHeaderField: "Origin")
                mediaReq.setValue("https://radiko.jp/", forHTTPHeaderField: "Referer")

                if let c = cookieString {
                    mediaReq.addValue(c, forHTTPHeaderField: "Cookie")
                }

                let (mData, _) = try await URLSession.shared.data(for: mediaReq)
                if let mBody = String(data: mData, encoding: .utf8) {
                    // print("Fetched Media Playlist (\(mBody.count) bytes)")
                    return (finalMediaURL, cookieString, mBody, validBaseURL)
                }

                return (finalMediaURL, cookieString, "", validBaseURL)
            }

            return (playlistURL, cookieString, content, validBaseURL)
        }
        return nil
    }
    // MARK: - Parallel Segment Downloading

    func startRecordingParallel(
        stationId: String, startTime: Date, endTime: Date, title: String, authToken: String,
        areaId: String, downloadID: UUID,
        result: (url: String, cookies: String?, content: String, baseURL: String),
        imageUrl: String? = nil
    ) async {
        let duration = Int(endTime.timeIntervalSince(startTime))
        let df = DateFormatter()
        df.dateFormat = "yyyyMMddHHmmss"
        let ft = df.string(from: startTime)
        let to = df.string(from: endTime)

        let dfDate = DateFormatter()
        dfDate.dateFormat = "yyyyMMdd"
        let dateStr = dfDate.string(from: startTime)
        let safeTitle = title.replacingOccurrences(of: "/", with: "_")
        let stationName =
            KikoProgramManager.shared.stations.first(where: { $0.id == stationId })?.name
            ?? stationId
        let fileName = "[\(dateStr)]_\(stationName)_\(safeTitle).m4a"
        let outputPath = (self.downloadPath as NSString).appendingPathComponent(fileName)

        print("Starting Parallel Download for: \(title)")

        // 1. Fetch all segments in chunks (max 3 mins each) to stay within server playlist limits
        var segmentURLs: [String] = []
        var currentOffset = 0
        let partDuration = 180  // 3 mins (server limit is strict for TimeFree)

        let validBaseURL = result.baseURL

        print("Gathering segments for \(duration)s program in \(partDuration)s chunks...")

        while currentOffset < duration {
            let remain = duration - currentOffset
            let chunkLen = min(partDuration, remain)

            do {
                if let chunk = try await fetchStreamURL(
                    stationId: stationId, ft: ft, to: to, duration: duration,
                    authToken: authToken, areaId: areaId,
                    seekOffset: currentOffset, length: chunkLen, forcedBaseURL: validBaseURL
                ) {
                    let parts = parseM3U8(content: chunk.content, baseURL: chunk.url)
                    // Avoid duplicates if segments overlap
                    for p in parts {
                        if !segmentURLs.contains(p) {
                            segmentURLs.append(p)
                        }
                    }
                }
            } catch {
                print("Failed to fetch chunk at offset \(currentOffset): \(error)")
                break
            }

            currentOffset += chunkLen
        }

        guard !segmentURLs.isEmpty else {
            print("No segments found in any chunks")
            return
        }

        print("Total segments collected: \(segmentURLs.count)")

        // 2. Prepare Headers
        let userAreaId = KikoAuthManager.shared.areaId ?? areaId
        var headers: [String: String] = [
            "User-Agent": userAgent,
            "X-Radiko-AuthToken": authToken,
            "X-Radiko-AreaId": userAreaId,
        ]
        if let cookies = result.cookies {
            headers["Cookie"] = cookies
        }

        // Temporary Directory
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            downloadID.uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // 3. Parallel Download
        do {
            let downloadedFiles = try await downloadSegmentsParallel(
                urls: segmentURLs, to: tempDir, headers: headers, downloadID: downloadID,
                totalSegments: segmentURLs.count)

            // 4. Concatenate
            if !downloadedFiles.isEmpty {
                await catenateSegments(files: downloadedFiles, to: URL(fileURLWithPath: outputPath))

                // Set Icon if available
                if let imgUrlStr = imageUrl, let imgUrl = URL(string: imgUrlStr) {
                    await self.setFileIcon(imageUrl: imgUrl, filePath: outputPath)
                }

                await MainActor.run {
                    let item = DownloadHistoryItem(
                        title: title, date: Date(), status: "完了", path: outputPath)
                    self.downloadHistory.insert(item, at: 0)
                    self.isRecording = false
                    self.currentRecordingTitle = nil
                }
            } else {
                throw NSError(
                    domain: "DownloadError", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No segments downloaded"])
            }
        } catch {
            print("Parallel Download Failed: \(error)")
            await MainActor.run {
                let item = DownloadHistoryItem(
                    title: title, date: Date(),
                    status: "失敗 (Parallel): \(error.localizedDescription)", path: "")
                self.downloadHistory.insert(item, at: 0)
                self.isRecording = false
            }
        }

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func parseM3U8(content: String, baseURL: String) -> [String] {
        var segments: [String] = []
        let lines = content.components(separatedBy: .newlines)

        let baseObj = URL(string: baseURL)
        let baseDir = baseObj?.deletingLastPathComponent()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                if trimmed.hasPrefix("http") {
                    segments.append(trimmed)
                } else if let base = baseDir {
                    // Relative URL
                    let absURL = base.appendingPathComponent(trimmed).absoluteString
                    segments.append(absURL)
                }
            }
        }
        return segments
    }

    private func downloadSegmentsParallel(
        urls: [String], to directory: URL, headers: [String: String], downloadID: UUID,
        totalSegments: Int
    ) async throws -> [URL] {
        // Prepare file mapping: index -> fileURL
        // Using TaskGroup with max concurrency

        return try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            var results: [Int: URL] = [:]
            var urlIterator = urls.enumerated().makeIterator()
            var activeCount = 0
            let maxParallel = 10

            // Initial batch
            while activeCount < maxParallel, let (index, urlStr) = urlIterator.next() {
                activeCount += 1
                group.addTask {
                    return try await self.downloadSegment(
                        index: index, urlStr: urlStr, to: directory, headers: headers)
                }
            }

            // Process and Add More
            while let result = try await group.next() {
                results[result.0] = result.1
                activeCount -= 1

                // Update Progress Helper
                let progress = Double(results.count) / Double(totalSegments)
                await MainActor.run {
                    if let idx = self.activeDownloads.firstIndex(where: { $0.id == downloadID }) {
                        self.activeDownloads[idx].progress = progress
                        if idx == 0 { self.recordingProgress = progress }
                    }
                }

                // Add next
                if let (index, urlStr) = urlIterator.next() {
                    activeCount += 1
                    group.addTask {
                        return try await self.downloadSegment(
                            index: index, urlStr: urlStr, to: directory, headers: headers)
                    }
                }
            }

            // Sort by index to ensure order
            let sortedFiles = results.sorted { $0.key < $1.key }.map { $0.value }
            return sortedFiles
        }
    }

    private func downloadSegment(
        index: Int, urlStr: String, to directory: URL, headers: [String: String]
    ) async throws -> (Int, URL) {
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let fileName = String(format: "%05d.aac", index)
        let fileURL = directory.appendingPathComponent(fileName)
        try data.write(to: fileURL)

        return (index, fileURL)
    }

    private func catenateSegments(files: [URL], to outputURL: URL) async {
        let fileManager = FileManager.default
        let listFileUrl = fileManager.temporaryDirectory.appendingPathComponent(
            "concat_list_\(UUID()).txt")

        var listContent = ""
        for file in files {
            listContent += "file '\(file.path)'\n"
        }

        do {
            try listContent.write(to: listFileUrl, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = [
                "-f", "concat",
                "-safe", "0",
                "-i", listFileUrl.path,
                "-c", "copy",
                "-bsf:a", "aac_adtstoasc",  // Crucial for AAC streams
                "-y",
                outputURL.path,
            ]

            try process.run()
            process.waitUntilExit()

            print("Concatenation finished with status: \(process.terminationStatus)")
            try? fileManager.removeItem(at: listFileUrl)

        } catch {
            print("Concatenation Error: \(error)")
        }
    }

    private func setFileIcon(imageUrl: URL, filePath: String) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: imageUrl)
            if let image = NSImage(data: data) {
                NSWorkspace.shared.setIcon(image, forFile: filePath, options: [])
            }
        } catch {
            print("Failed to set file icon: \(error)")
        }
    }
}
