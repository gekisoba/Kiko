import Combine
import SwiftUI

struct KikoStation: Identifiable, Hashable {
    let id: String
    let name: String
    let logo: String?
    let areaId: String
}

struct KikoProgram: Identifiable, Hashable {
    let id: String
    let title: String
    let description: String
    let startTime: Date
    let endTime: Date
    let stationId: String
    let performers: String
    let imageUrl: String?

    var durationFormatted: String {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: startTime, to: endTime)
    }
}

@MainActor
class KikoProgramManager: NSObject, ObservableObject {
    static let shared = KikoProgramManager()

    @Published var stations: [KikoStation] = []
    @Published var programs: [String: [KikoProgram]] = [:]
    @Published var isLoading = false
    @Published var currentAreaId: String = "JP13"

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMddHHmmss"
        return df
    }()

    override private init() {
        super.init()
    }

    func searchPrograms(keyword: String) async -> [KikoProgram] {
        let today = Date()
        var allPrograms: [KikoProgram] = []

        // Search past 7 days (including today)
        // 0 to -6
        await withTaskGroup(of: [KikoProgram].self) { group in
            for i in 0..<8 {
                guard let date = Calendar.current.date(byAdding: .day, value: -i, to: today)
                else { continue }

                group.addTask {
                    return await self.fetchProgramsInternal(date: date, areaId: self.currentAreaId)
                }
            }

            for await programs in group {
                allPrograms.append(contentsOf: programs)
            }
        }

        // Filter by keyword
        return allPrograms.filter {
            $0.title.localizedCaseInsensitiveContains(keyword)
        }
    }

    // Internal fetcher that doesn't update Published properties directly (avoids UI flicker)
    private func fetchProgramsInternal(date: Date, areaId: String) async -> [KikoProgram] {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        let dateStr = df.string(from: date)
        let urlString = "https://radiko.jp/v3/program/date/\(dateStr)/\(areaId).xml"

        guard let url = URL(string: urlString) else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url))
            // Parse manually
            let parser = XMLParser(data: data)
            let radikoParser = KikoXMLParser(areaId: areaId)
            parser.delegate = radikoParser
            parser.parse()

            // Flatten programs
            return radikoParser.programs.values.flatMap { $0 }
        } catch {
            return []
        }
    }

    func fetchPrograms(date: Date = Date(), areaId: String? = nil) async {
        let targetAreaId = areaId ?? currentAreaId
        self.currentAreaId = targetAreaId

        isLoading = true

        // Date formatting for API
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        let dateStr = df.string(from: date)

        let urlString = "https://radiko.jp/v3/program/date/\(dateStr)/\(targetAreaId).xml"

        guard let url = URL(string: urlString) else {
            isLoading = false
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url))
            parseXML(data: data, areaId: targetAreaId)
        } catch {
        }
        isLoading = false
    }

    private func parseXML(data: Data, areaId: String) {
        let parser = XMLParser(data: data)
        let radikoParser = KikoXMLParser(areaId: areaId)
        parser.delegate = radikoParser
        parser.parse()

        self.stations = radikoParser.stations
        self.programs = radikoParser.programs
    }
}

// Separate Parser to avoid actor isolation issues with XMLParserDelegate
class KikoXMLParser: NSObject, XMLParserDelegate {
    var stations: [KikoStation] = []
    var programs: [String: [KikoProgram]] = [:]
    let areaId: String

    init(areaId: String) {
        self.areaId = areaId
        super.init()
    }

    private var currentStationId: String?
    private var currentStationName: String = ""
    private var currentPrograms: [KikoProgram] = []
    private var currentElement = ""
    private var currentProgramData: [String: String] = [:]

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMddHHmmss"
        return df
    }()

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        if elementName == "station" {
            currentStationId = attributeDict["id"]
            currentStationName = ""
            currentPrograms = []
        } else if elementName == "prog" {
            currentProgramData = [:]
            currentProgramData["id"] = attributeDict["id"]
            currentProgramData["ft"] = attributeDict["ft"]
            currentProgramData["to"] = attributeDict["to"]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let data = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !data.isEmpty else { return }

        if currentElement == "name" && currentStationId != nil && currentProgramData.isEmpty {
            currentStationName += data
        } else if currentElement == "title" {
            currentProgramData["title"] = (currentProgramData["title"] ?? "") + data
        } else if currentElement == "sub_title" {
            currentProgramData["sub_title"] = (currentProgramData["sub_title"] ?? "") + data
        } else if currentElement == "desc" {
            currentProgramData["desc"] = (currentProgramData["desc"] ?? "") + data
        } else if currentElement == "pf" {
            currentProgramData["pf"] = (currentProgramData["pf"] ?? "") + data
        } else if currentElement == "img" {
            currentProgramData["img"] = (currentProgramData["img"] ?? "") + data
        }

    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "station" {
            if let id = currentStationId {
                stations.append(
                    KikoStation(id: id, name: currentStationName, logo: nil, areaId: areaId))
                programs[id] = currentPrograms
            }
            currentStationId = nil
        } else if elementName == "prog" {
            if let stationId = currentStationId,
                let id = currentProgramData["id"],
                currentProgramData["title"] != nil,
                let ft = currentProgramData["ft"],
                let to = currentProgramData["to"],
                let startTime = dateFormatter.date(from: ft),
                let endTime = dateFormatter.date(from: to)
            {

                let rawTitle = currentProgramData["title"] ?? ""
                let subTitle = currentProgramData["sub_title"] ?? ""
                let fullTitle = subTitle.isEmpty ? rawTitle : "\(rawTitle) \(subTitle)"

                // Helper to normalize title for matching split programs
                func normalizeTitle(_ title: String) -> String {
                    var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Remove trailing parts like (1), (2), [1], [2], 第1部, Part 1 etc.
                    let patterns = [
                        "\\s*[\\(\\[（［]\\d+[\\)\\]）］]$",  // (1), [1], （１）
                        "\\s*第?\\d+部$",  // 第1部, 2部
                        "\\s*Part\\s*\\d+$",  // Part 1
                        "\\s*#\\d+$",  // #1
                    ]
                    for pattern in patterns {
                        if let range = t.range(of: pattern, options: .regularExpression) {
                            t.removeSubrange(range)
                        }
                    }
                    return t.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                let normalizedCurrent = normalizeTitle(fullTitle)

                // Check for continuation (split programs like Part 1, Part 2)
                if let last = currentPrograms.last,
                    normalizeTitle(last.title) == normalizedCurrent,
                    abs(last.endTime.timeIntervalSince(startTime)) < 300  // Allow up to 5 mins gap for split programs
                {
                    // Merge: update the end time of the last program
                    let mergedProgram = KikoProgram(
                        id: last.id,
                        title: normalizedCurrent,
                        description: last.description,
                        startTime: last.startTime,
                        endTime: endTime,
                        stationId: last.stationId,
                        performers: last.performers,
                        imageUrl: last.imageUrl
                    )
                    currentPrograms[currentPrograms.count - 1] = mergedProgram
                } else {
                    // Ensure ID is unique by appending start time
                    let uniqueId = "\(id)_\(ft)"

                    let program = KikoProgram(
                        id: uniqueId,
                        title: fullTitle,
                        description: currentProgramData["desc"] ?? "",
                        startTime: startTime,
                        endTime: endTime,
                        stationId: stationId,
                        performers: currentProgramData["pf"] ?? "",
                        imageUrl: currentProgramData["img"]
                    )
                    currentPrograms.append(program)
                }
            }
            currentProgramData = [:]
        }
        currentElement = ""

    }
}
