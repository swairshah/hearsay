import Foundation

do {
    try await Command(arguments: Array(CommandLine.arguments.dropFirst())).run()
} catch let error as CLIError {
    stderr("hearsay: \(error.message)")
    exit(error.exitCode)
} catch {
    stderr("hearsay: \(error.localizedDescription)")
    exit(1)
}

private struct Command {
    var arguments: [String]

    func run() async throws {
        guard let name = arguments.first else {
            printHelp()
            return
        }

        let rest = Array(arguments.dropFirst())
        switch name {
        case "api":
            try printAPIInfo()
        case "health":
            try await health()
        case "open":
            try runProcess("/usr/bin/open", ["-a", "Hearsay"])
        case "quit", "close":
            try runProcess("/usr/bin/osascript", ["-e", "tell application id \"com.swair.hearsay\" to quit"])
        case "dictate":
            try await dictate(rest)
        case "stop":
            try await control(rest, action: "stop")
        case "cancel":
            try await control(rest, action: "cancel")
        case "history":
            try history(rest)
        case "help", "--help", "-h":
            printHelp()
        default:
            throw CLIError("unknown command '\(name)'", exitCode: 64)
        }
    }

    private func printAPIInfo() throws {
        let info = try LocalAPIInfo.load()
        print("http://\(info.host):\(info.port)")
    }

    private func health() async throws {
        let data = try await APIClient().request(method: "GET", path: "/v1/health")
        printPrettyJSON(data)
    }

    private func dictate(_ args: [String]) async throws {
        var parser = ArgumentParser(args)
        let caller = try parser.stringValue(after: "--caller") ?? "hearsay-cli"
        let requestId = try parser.stringValue(after: "--request-id") ?? UUID().uuidString
        let jsonOutput = parser.flag("--json")
        let stopOnEnter = parser.flag("--stop-on-enter")
        try parser.rejectUnused()

        guard UUID(uuidString: requestId) != nil else {
            throw CLIError("--request-id must be a UUID", exitCode: 64)
        }

        let body = StartDictationRequest(
            caller: caller,
            mode: "returnToCaller",
            requestId: requestId,
            metadata: ["source": "hearsay-cli"]
        )

        stderr("requestId: \(requestId)")

        let client = APIClient(timeout: 60 * 60)
        let resultTask = Task {
            try await client.request(
                method: "POST",
                path: "/v1/dictations",
                body: try JSONEncoder().encode(body)
            )
        }

        if stopOnEnter {
            stderr("Recording. Press Enter to stop.")
            _ = readLine()
            do {
                _ = try await client.request(method: "POST", path: "/v1/dictations/\(requestId)/stop")
            } catch let error as CLIError {
                stderr("stop request did not change state: \(error.message)")
            }
        }

        let resultData = try await resultTask.value
        if jsonOutput {
            printPrettyJSON(resultData)
            return
        }

        let result = try JSONDecoder().decode(DictationResult.self, from: resultData)
        switch result.status {
        case "completed":
            print(result.text ?? "")
        case "cancelled":
            throw CLIError("dictation cancelled", exitCode: 130)
        default:
            throw CLIError(result.error ?? "dictation failed", exitCode: 1)
        }
    }

    private func control(_ args: [String], action: String) async throws {
        guard args.count == 1, let requestId = args.first else {
            throw CLIError("usage: hearsay \(action) REQUEST_ID", exitCode: 64)
        }
        guard UUID(uuidString: requestId) != nil else {
            throw CLIError("REQUEST_ID must be a UUID", exitCode: 64)
        }

        let data = try await APIClient().request(method: "POST", path: "/v1/dictations/\(requestId)/\(action)")
        printPrettyJSON(data)
    }

    private func history(_ args: [String]) throws {
        var parser = ArgumentParser(args)
        let limit = try parser.intValue(after: "--limit") ?? 10
        let jsonOutput = parser.flag("--json")
        try parser.rejectUnused()

        let items = try HistoryReader().recent(limit: limit)
        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(data: try encoder.encode(items), encoding: .utf8) ?? "[]")
            return
        }

        if items.isEmpty {
            print("No transcriptions yet")
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for item in items {
            let text = item.text.replacingOccurrences(of: "\n", with: " ")
            let preview = text.count > 90 ? String(text.prefix(87)) + "..." : text
            print("\(formatter.string(from: item.timestamp))  \(preview)")
        }
    }

    private func printHelp() {
        print("""
        Usage:
          hearsay open
          hearsay quit
          hearsay api
          hearsay health
          hearsay dictate [--caller NAME] [--request-id UUID] [--json] [--stop-on-enter]
          hearsay stop REQUEST_ID
          hearsay cancel REQUEST_ID
          hearsay history [--limit N] [--json]
        """)
    }
}

private struct APIClient {
    var timeout: TimeInterval = 30

    func request(method: String, path: String, body: Data? = nil) async throws -> Data {
        let info = try LocalAPIInfo.load()
        guard let url = URL(string: "http://\(info.host):\(info.port)\(path)") else {
            throw CLIError("invalid local API URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw CLIError("Hearsay local API is not reachable. Run 'hearsay open' and try again.")
        }

        guard let http = response as? HTTPURLResponse else {
            throw CLIError("local API did not return an HTTP response")
        }

        guard (200..<300).contains(http.statusCode) else {
            if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw CLIError(apiError.message, exitCode: http.statusCode == 409 ? 75 : 1)
            }
            throw CLIError("local API returned HTTP \(http.statusCode)")
        }

        return data
    }
}

private struct LocalAPIInfo: Decodable {
    let host: String
    let port: Int
    let version: Int

    static func load() throws -> LocalAPIInfo {
        let url = appSupportDirectory().appendingPathComponent("local-api.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError("Hearsay is not running. Run 'hearsay open' first.")
        }
        return try JSONDecoder().decode(LocalAPIInfo.self, from: Data(contentsOf: url))
    }
}

private struct StartDictationRequest: Encodable {
    let caller: String
    let mode: String
    let requestId: String
    let metadata: [String: String]
}

private struct DictationResult: Decodable {
    let requestId: String
    let status: String
    let text: String?
    let error: String?
    let durationSeconds: Double?
}

private struct APIErrorResponse: Decodable {
    let error: String
    let message: String
}

private struct HistoryReader {
    func recent(limit: Int) throws -> [HistoryItem] {
        guard limit > 0 else { return [] }
        let indexURL = historyDirectory().appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return []
        }

        let index = try JSONDecoder().decode(HistoryIndex.self, from: Data(contentsOf: indexURL))
        var items: [HistoryItem] = []
        for chunk in index.chunks {
            let chunkURL = historyDirectory().appendingPathComponent(String(format: "chunk_%04d.json", chunk.id))
            guard FileManager.default.fileExists(atPath: chunkURL.path) else {
                continue
            }
            let chunkItems = try JSONDecoder().decode([HistoryItem].self, from: Data(contentsOf: chunkURL))
            items.append(contentsOf: chunkItems.prefix(max(0, limit - items.count)))
            if items.count >= limit {
                break
            }
        }
        return items
    }
}

private struct HistoryIndex: Decodable {
    struct Chunk: Decodable {
        let id: Int
        let count: Int
    }

    let nextChunkId: Int
    let chunks: [Chunk]
}

private struct HistoryItem: Codable {
    let id: UUID
    let text: String
    let timestamp: Date
    let durationSeconds: Double
    let audioFilePath: String?
}

private struct ArgumentParser {
    private var args: [String]
    private var used: Set<Int> = []

    init(_ args: [String]) {
        self.args = args
    }

    mutating func flag(_ name: String) -> Bool {
        guard let index = args.firstIndex(of: name) else {
            return false
        }
        used.insert(index)
        return true
    }

    mutating func stringValue(after name: String) throws -> String? {
        guard let index = args.firstIndex(of: name) else {
            return nil
        }
        used.insert(index)
        let valueIndex = index + 1
        guard valueIndex < args.count else {
            throw CLIError("\(name) requires a value", exitCode: 64)
        }
        used.insert(valueIndex)
        return args[valueIndex]
    }

    mutating func intValue(after name: String) throws -> Int? {
        guard let raw = try stringValue(after: name) else {
            return nil
        }
        guard let value = Int(raw) else {
            throw CLIError("\(name) requires an integer", exitCode: 64)
        }
        return value
    }

    func rejectUnused() throws {
        for (index, arg) in args.enumerated() where !used.contains(index) {
            throw CLIError("unexpected argument '\(arg)'", exitCode: 64)
        }
    }
}

private struct CLIError: Error {
    let message: String
    let exitCode: Int32

    init(_ message: String, exitCode: Int32 = 1) {
        self.message = message
        self.exitCode = exitCode
    }
}

private func appSupportDirectory() -> URL {
    FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hearsay", isDirectory: true)
}

private func historyDirectory() -> URL {
    appSupportDirectory().appendingPathComponent("History", isDirectory: true)
}

private func printPrettyJSON(_ data: Data) {
    guard
        let object = try? JSONSerialization.jsonObject(with: data),
        let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
        let string = String(data: pretty, encoding: .utf8)
    else {
        print(String(data: data, encoding: .utf8) ?? "")
        return
    }
    print(string)
}

private func stderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func runProcess(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CLIError("\(URL(fileURLWithPath: executable).lastPathComponent) exited with \(process.terminationStatus)")
    }
}
