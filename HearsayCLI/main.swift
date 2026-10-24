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
        case "logs":
            try logs(rest)
        case "mic", "microphone":
            try await mic(rest)
        case "meeting":
            try await meeting(rest)
        case "meetings":
            try await meetings(rest)
        case "vocab", "vocabulary":
            try vocab(rest)
        case "help", "--help", "-h":
            printHelp()
        default:
            throw CLIError("unknown command '\(name)'", exitCode: 64)
        }
    }

    private func logs(_ args: [String]) throws {
        var parser = ArgumentParser(args)
        let printPath = parser.flag("--path")
        let openLog = parser.flag("--open")
        let copyLog = parser.flag("--copy")
        let clearLog = parser.flag("--clear")
        try parser.rejectUnused()

        let reader = DiagnosticLogReader()

        if clearLog {
            try reader.clear()
            print("Diagnostic log cleared")
            return
        }

        if printPath {
            print(reader.logURL.path)
            return
        }

        let snapshot = try reader.snapshotText()

        if copyLog {
            try runProcess("/usr/bin/pbcopy", [], standardInput: Data(snapshot.utf8))
            stderr("Copied metadata-only diagnostic logs to clipboard")
        }

        if openLog {
            let snapshotURL = try reader.writeSnapshotFile(text: snapshot)
            try runProcess("/usr/bin/open", [snapshotURL.path])
        }

        if !copyLog && !openLog {
            print(snapshot, terminator: snapshot.hasSuffix("\n") ? "" : "\n")
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
          hearsay logs [--open] [--copy] [--path] [--clear]
          hearsay mic <list|get|set>
          hearsay meeting <start|stop|status>
          hearsay meetings [list|show|search|path]
          hearsay vocab [list|search|add|edit|remove|path|export]

        Run 'hearsay meetings help' for reading saved meeting transcripts,
        'hearsay vocab help' for names and terms the speech model should get right.
        """)
    }

    // MARK: - Meetings

    private func meeting(_ arguments: [String]) async throws {
        guard let action = arguments.first else {
            printMeetingHelp()
            return
        }
        var parser = ArgumentParser(Array(arguments.dropFirst()))
        let client = APIClient()

        switch action {
        case "start":
            let title = try parser.stringValue(after: "--title")
            let replayMic = try parser.stringValue(after: "--replay-mic")
            let replaySystem = try parser.stringValue(after: "--replay-system")
            let speed = try parser.stringValue(after: "--speed").map { raw -> Double in
                guard let value = Double(raw), value > 0 else { throw CLIError("--speed requires a positive number", exitCode: 64) }
                return value
            }
            try parser.rejectUnused()

            var body: [String: Any] = [:]
            if let title { body["title"] = title }
            if replayMic != nil || replaySystem != nil {
                var replay: [String: Any] = [:]
                if let replayMic { replay["microphone"] = absolutePath(replayMic) }
                if let replaySystem { replay["system"] = absolutePath(replaySystem) }
                if let speed { replay["speed"] = speed }
                body["replay"] = replay
            }
            let data = try await client.request(method: "POST", path: "/v1/meetings", body: try JSONSerialization.data(withJSONObject: body))
            let response = try JSONDecoder().decode(MeetingStartResponse.self, from: data)
            print(response.id)

        case "stop":
            let wait = parser.flag("--wait")
            try parser.rejectUnused()
            let data = try await client.request(method: "POST", path: "/v1/meetings/stop")
            let response = try JSONDecoder().decode(MeetingStartResponse.self, from: data)
            if wait {
                stderr("Finishing transcript…")
                while true {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    let status = try JSONDecoder().decode(MeetingStatusResponse.self, from: try await client.request(method: "GET", path: "/v1/meetings/current"))
                    if status.id != response.id { break }
                }
            }
            print(response.id)

        case "status":
            let json = parser.flag("--json")
            try parser.rejectUnused()
            let data = try await client.request(method: "GET", path: "/v1/meetings/current")
            if json {
                printPrettyJSON(data)
                return
            }
            let status = try JSONDecoder().decode(MeetingStatusResponse.self, from: data)
            guard let id = status.id else {
                print("Not recording")
                return
            }
            let elapsed = MeetingTranscriptFormatter.timestamp(status.elapsedSeconds ?? 0)
            print("\(status.phase ?? "recording")  \(elapsed)  \(status.title ?? "")  (\(status.shortId ?? id))")
            print("\(status.segments ?? 0) lines · call audio: \(status.systemAudio == true ? "yes" : "no") · speakers: \(status.speakerDetection ?? "off")")

        case "help", "--help", "-h":
            printMeetingHelp()
        default:
            throw CLIError("unknown meeting command '\(action)'\n\nRun 'hearsay meeting help' for usage.", exitCode: 64)
        }
    }

    private func meetings(_ arguments: [String]) async throws {
        let action = arguments.first ?? "list"
        let known = ["list", "ls", "show", "cat", "search", "path", "open", "help", "--help", "-h"]
        // `hearsay meetings --limit 5` means list.
        let rest = known.contains(action) ? Array(arguments.dropFirst()) : arguments
        var parser = ArgumentParser(rest)
        let library = MeetingLibrary()

        switch known.contains(action) ? action : "list" {
        case "list", "ls":
            let limit = try parser.intValue(after: "--limit") ?? 20
            let date = try parser.stringValue(after: "--date")
            let json = parser.flag("--json")
            try parser.rejectUnused()

            var summaries = try library.summaries()
            if let date {
                let day = try parseDay(date)
                summaries = summaries.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }
            }
            summaries = Array(summaries.prefix(max(0, limit)))
            if json {
                print(String(data: try MeetingCoding.makeEncoder().encode(summaries), encoding: .utf8) ?? "[]")
                return
            }
            if summaries.isEmpty {
                print("No meetings")
                return
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            for summary in summaries {
                let duration = MeetingTranscriptFormatter.durationText(summary.durationSeconds)
                let live = summary.status == .recording ? "  [recording]" : ""
                print("\(summary.shortID)  \(formatter.string(from: summary.startedAt))  \(duration.padding(toLength: 9, withPad: " ", startingAt: 0))  \(summary.title)\(live)")
            }

        case "show", "cat":
            let format = try parser.stringValue(after: "--format") ?? "markdown"
            let original = parser.flag("--original")
            let noTimestamps = parser.flag("--no-timestamps")
            guard let reference = parser.positionalArgument() else {
                throw CLIError("usage: hearsay meetings show <id|latest> [--format markdown|text|json] [--original] [--no-timestamps]", exitCode: 64)
            }
            try parser.rejectUnused()
            let document = try library.document(matching: reference)
            switch format {
            case "markdown", "md":
                print(MeetingTranscriptFormatter.markdown(for: document, original: original, timestamps: !noTimestamps))
            case "text", "txt", "plain":
                print(MeetingTranscriptFormatter.plainText(for: document, original: original, timestamps: !noTimestamps))
            case "json":
                print(String(data: try MeetingCoding.makeEncoder().encode(document), encoding: .utf8) ?? "{}")
            default:
                throw CLIError("--format must be markdown, text, or json", exitCode: 64)
            }

        case "search":
            let limit = try parser.intValue(after: "--limit") ?? 50
            let json = parser.flag("--json")
            guard let query = parser.positionalArgument() else {
                throw CLIError("usage: hearsay meetings search <query> [--limit N] [--json]", exitCode: 64)
            }
            try parser.rejectUnused()
            var hits: [MeetingSearchHitOutput] = []
            for summary in try library.summaries() {
                guard let document = try? library.document(id: summary.id) else { continue }
                for hit in MeetingSearch.hits(in: document, query: query) {
                    guard let segment = document.segments.first(where: { $0.id == hit.segmentID }) else { continue }
                    hits.append(MeetingSearchHitOutput(
                        meetingId: document.id.uuidString,
                        shortId: document.shortID,
                        title: document.title,
                        startedAt: document.startedAt,
                        offsetSeconds: segment.start,
                        speaker: document.speakerName(for: segment),
                        text: segment.text
                    ))
                    if hits.count >= limit { break }
                }
                if hits.count >= limit { break }
            }
            if json {
                print(String(data: try MeetingCoding.makeEncoder().encode(hits), encoding: .utf8) ?? "[]")
                return
            }
            if hits.isEmpty {
                print("No matches")
                return
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            for hit in hits {
                print("\(hit.shortId) \(formatter.string(from: hit.startedAt)) [\(MeetingTranscriptFormatter.timestamp(hit.offsetSeconds))] \(hit.speaker): \(MeetingSearch.snippet(for: query, in: hit.text, radius: 70))")
            }

        case "open":
            var body: [String: String] = [:]
            if let view = try parser.stringValue(after: "--view") {
                guard ["transcript", "reader", "speakers"].contains(view) else {
                    throw CLIError("--view must be transcript, reader, or speakers", exitCode: 64)
                }
                body["view"] = view
            }
            if let reference = parser.positionalArgument() {
                body["id"] = try library.document(matching: reference).id.uuidString
            }
            try parser.rejectUnused()
            _ = try await APIClient().request(method: "POST", path: "/v1/meetings/open", body: try JSONEncoder().encode(body))

        case "path":
            guard let reference = parser.positionalArgument() else {
                print(MeetingPaths.rootDirectory.path)
                return
            }
            try parser.rejectUnused()
            let document = try library.document(matching: reference)
            print(MeetingPaths.directory(for: document.id).path)

        default:
            printMeetingsHelp()
        }
    }

    private func parseDay(_ value: String) throws -> Date {
        switch value.lowercased() {
        case "today": return Date()
        case "yesterday": return Date().addingTimeInterval(-86_400)
        default:
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            guard let date = formatter.date(from: value) else {
                throw CLIError("--date must be YYYY-MM-DD, today, or yesterday", exitCode: 64)
            }
            return date
        }
    }

    private func absolutePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded).standardized.path
    }

    private func printMeetingHelp() {
        print("""
        Usage:
          hearsay meeting start [--title TITLE]
          hearsay meeting start --replay-mic FILE [--replay-system FILE] [--speed N]
          hearsay meeting stop [--wait]
          hearsay meeting status [--json]

        'start --replay-*' runs audio files through the live pipeline instead of
        the microphone and call audio (for testing). --speed 4 replays 4x faster.
        """)
    }

    private func printMeetingsHelp() {
        print("""
        Usage:
          hearsay meetings [list] [--limit N] [--date YYYY-MM-DD|today|yesterday] [--json]
          hearsay meetings show <id|latest> [--format markdown|text|json] [--original] [--no-timestamps]
          hearsay meetings search <query> [--limit N] [--json]
          hearsay meetings path [<id|latest>]
          hearsay meetings open [<id|latest>] [--view transcript|reader|speakers]

        IDs can be shortened to any unique prefix (the 8-character id from 'list').
        'show' prints the processed transcript; --original prints the raw speech-to-text.
        Transcripts live in \(MeetingPaths.rootDirectory.path)/<id>/ (meeting.json, transcript.md).
        """)
    }

    // MARK: - Vocabulary

    private func vocab(_ arguments: [String]) throws {
        let action = arguments.first ?? "list"
        var parser = ArgumentParser(Array(arguments.dropFirst()))
        let url = Vocabulary.fileURL

        switch action {
        case "list", "ls":
            let json = parser.flag("--json")
            try parser.rejectUnused()
            try printVocabulary(try Vocabulary.load(from: url).sorted, json: json, empty: "No vocabulary terms")

        case "search", "find":
            let json = parser.flag("--json")
            guard let query = parser.positionalArgument() else {
                throw CLIError("usage: hearsay vocab search <query> [--json]", exitCode: 64)
            }
            try parser.rejectUnused()
            try printVocabulary(try Vocabulary.load(from: url).search(query), json: json, empty: "No terms match '\(query)'")

        case "add":
            let aliases = try parser.stringValues(after: "--alias")
            let note = try parser.stringValue(after: "--note")
            guard let text = parser.positionalArgument() else {
                throw CLIError("usage: hearsay vocab add <term> [--alias A]... [--note N]", exitCode: 64)
            }
            try parser.rejectUnused()
            var vocabulary = try Vocabulary.load(from: url)
            let term = try vocabulary.add(text, aliases: aliases, note: note)
            try vocabulary.save(to: url)
            print("Added \(describe(term))")

        case "edit", "update":
            let newText = try parser.stringValue(after: "--text")
            let replaceAliases = try parser.stringValues(after: "--alias")
            let addAliases = try parser.stringValues(after: "--add-alias")
            let removeAliases = try parser.stringValues(after: "--remove-alias")
            let note = try parser.stringValue(after: "--note")
            guard let reference = parser.positionalArgument() else {
                throw CLIError("usage: hearsay vocab edit <term|id> [--text T] [--alias A]... [--add-alias A]... [--remove-alias A]... [--note N]", exitCode: 64)
            }
            try parser.rejectUnused()
            var vocabulary = try Vocabulary.load(from: url)
            guard var term = vocabulary.find(reference) else {
                throw CLIError("no vocabulary term '\(reference)'")
            }
            if let newText { term.text = newText }
            var aliases = replaceAliases.isEmpty ? term.aliases : replaceAliases
            aliases += addAliases
            let removing = Set(removeAliases.map(Vocabulary.matchKey))
            aliases.removeAll { removing.contains(Vocabulary.matchKey($0)) }
            term.aliases = aliases
            if let note { term.setNote(note) }
            try vocabulary.update(term)
            try vocabulary.save(to: url)
            print("Updated \(describe(vocabulary.find(term.text) ?? term))")

        case "remove", "rm", "delete":
            guard let reference = parser.positionalArgument() else {
                throw CLIError("usage: hearsay vocab remove <term|id>", exitCode: 64)
            }
            try parser.rejectUnused()
            var vocabulary = try Vocabulary.load(from: url)
            guard let term = vocabulary.find(reference) else {
                throw CLIError("no vocabulary term '\(reference)'")
            }
            vocabulary.remove(id: term.id)
            try vocabulary.save(to: url)
            print("Removed \(term.text)")

        case "path":
            try parser.rejectUnused()
            print(url.path)

        case "export":
            let format = try parser.stringValue(after: "--format") ?? "json"
            try parser.rejectUnused()
            let vocabulary = try Vocabulary.load(from: url)
            switch format {
            case "json":
                print(String(data: try MeetingCoding.makeEncoder().encode(vocabulary), encoding: .utf8) ?? "{}")
            case "fluidaudio", "simple":
                print(vocabulary.fluidAudioSimpleFormat(), terminator: "")
            default:
                throw CLIError("--format must be json or fluidaudio", exitCode: 64)
            }

        case "help", "--help", "-h":
            printVocabHelp()

        default:
            throw CLIError("unknown vocab command '\(action)'", exitCode: 64)
        }
    }

    private func printVocabulary(_ terms: [VocabularyTerm], json: Bool, empty: String) throws {
        if json {
            print(String(data: try MeetingCoding.makeEncoder().encode(terms), encoding: .utf8) ?? "[]")
            return
        }
        if terms.isEmpty {
            print(empty)
            return
        }
        for term in terms {
            print(describe(term))
        }
    }

    private func describe(_ term: VocabularyTerm) -> String {
        var line = "\(term.shortID)  \(term.text)"
        if !term.aliases.isEmpty { line += "  ← \(term.aliases.joined(separator: ", "))" }
        if let note = term.note { line += "  (\(note))" }
        return line
    }

    private func printVocabHelp() {
        print("""
        Usage:
          hearsay vocab [list] [--json]
          hearsay vocab search <query> [--json]
          hearsay vocab add <term> [--alias A]... [--note N]
          hearsay vocab edit <term|id> [--text T] [--alias A]... [--add-alias A]... [--remove-alias A]... [--note N]
          hearsay vocab remove <term|id>
          hearsay vocab path
          hearsay vocab export [--format json|fluidaudio]

        Aliases are how the speech model mishears a term ("human lair" for HumanLayer);
        Hearsay replaces them with the term in dictation and meeting transcripts, and the
        LLM passes get the term list as a spelling reference. 'edit --alias' replaces all
        aliases; --add-alias / --remove-alias change them one at a time. Changes apply to
        the next transcription; the app doesn't need to be running.
        File: \(Vocabulary.fileURL.path)
        """)
    }

    private func mic(_ arguments: [String]) async throws {
        guard let action = arguments.first else {
            printMicHelp()
            return
        }

        let rest = Array(arguments.dropFirst())
        switch action {
        case "list", "ls":
            try await micList(rest)
        case "get", "current", "status":
            try await micGet(rest)
        case "set", "select":
            try await micSet(rest)
        case "help", "--help", "-h":
            printMicHelp()
        default:
            throw CLIError("unknown mic command '\(action)'\n\nRun 'hearsay mic help' for usage.", exitCode: 64)
        }
    }

    private func micList(_ arguments: [String]) async throws {
        var parser = ArgumentParser(arguments)
        let jsonOutput = parser.flag("--json")
        try parser.rejectUnused()

        let client = APIClient()
        let data = try await client.request(method: "GET", path: "/v1/microphones")

        if jsonOutput {
            printPrettyJSON(data)
            return
        }

        struct DeviceInfo: Decodable {
            let uid: String
            let name: String
            let isBuiltIn: Bool
            let isActive: Bool?
            let isSelected: Bool?
        }
        struct MicListResponse: Decodable {
            let devices: [DeviceInfo]
            let activeDevice: DeviceInfo?
            let selectedUID: String?
        }

        let resp = try JSONDecoder().decode(MicListResponse.self, from: data)
        guard !resp.devices.isEmpty else {
            print("No microphones found.")
            return
        }

        for dev in resp.devices {
            var badges: [String] = []
            if dev.isActive == true {
                badges.append("active")
            }
            if dev.isSelected == true {
                badges.append("selected")
            } else if dev.isActive == true && resp.selectedUID == nil {
                badges.append("system default")
            }
            if dev.isBuiltIn {
                badges.append("built-in")
            }
            let badgeStr = badges.isEmpty ? "" : " (\(badges.joined(separator: ", ")))"
            let prefix = (dev.isActive == true) ? "* " : "  "
            print("\(prefix)\(dev.name)\(badgeStr)")
            print("    UID: \(dev.uid)")
        }
    }

    private func micGet(_ arguments: [String]) async throws {
        var parser = ArgumentParser(arguments)
        let jsonOutput = parser.flag("--json")
        try parser.rejectUnused()

        let client = APIClient()
        let data = try await client.request(method: "GET", path: "/v1/microphones/current")

        if jsonOutput {
            printPrettyJSON(data)
            return
        }

        struct DeviceInfo: Decodable {
            let uid: String
            let name: String
            let isBuiltIn: Bool
        }
        struct MicCurrentResponse: Decodable {
            let activeDevice: DeviceInfo?
            let selectedUID: String?
        }

        let resp = try JSONDecoder().decode(MicCurrentResponse.self, from: data)
        if let active = resp.activeDevice {
            let builtInStr = active.isBuiltIn ? " (Built-in)" : ""
            print("Active: \(active.name)\(builtInStr)")
            print("UID: \(active.uid)")
            if let selectedUID = resp.selectedUID {
                print("Selection: Explicit (\(selectedUID))")
            } else {
                print("Selection: System Default (auto)")
            }
        } else {
            print("No active microphone.")
        }
    }

    private func micSet(_ arguments: [String]) async throws {
        var parser = ArgumentParser(arguments)
        let jsonOutput = parser.flag("--json")
        guard let target = parser.positionalArgument() else {
            throw CLIError("Usage: hearsay mic set <name-or-uid|default> [--json]", exitCode: 64)
        }
        try parser.rejectUnused()

        let client = APIClient()
        let payload = ["uid": target]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await client.request(method: "POST", path: "/v1/microphones/select", body: body)

        if jsonOutput {
            printPrettyJSON(data)
            return
        }

        struct DeviceInfo: Decodable {
            let uid: String
            let name: String
            let isBuiltIn: Bool
        }
        struct MicSetResponse: Decodable {
            let ok: Bool
            let activeDevice: DeviceInfo?
            let selectedUID: String?
        }

        let resp = try JSONDecoder().decode(MicSetResponse.self, from: data)
        if let active = resp.activeDevice {
            if resp.selectedUID == nil {
                print("Microphone set to System Default (auto).")
                print("Active: \(active.name) [\(active.uid)]")
            } else {
                print("Microphone selected: \(active.name)")
                print("UID: \(active.uid)")
            }
        } else {
            print("Microphone updated, but no active microphone detected.")
        }
    }

    private func printMicHelp() {
        print("""
        Usage:
          hearsay mic list [--json]
          hearsay mic get [--json]
          hearsay mic set <name-or-uid|default> [--json]

        Commands:
          list, ls          List available audio input devices
          get, current      Show active microphone details
          set, select       Select microphone by name/UID or reset with 'default'
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

private struct MeetingStartResponse: Decodable {
    let id: String
}

private struct MeetingStatusResponse: Decodable {
    let recording: Bool
    let phase: String?
    let id: String?
    let shortId: String?
    let title: String?
    let elapsedSeconds: Double?
    let segments: Int?
    let systemAudio: Bool?
    let speakerDetection: String?
}

private struct MeetingSearchHitOutput: Encodable {
    let meetingId: String
    let shortId: String
    let title: String
    let startedAt: Date
    let offsetSeconds: Double
    let speaker: String
    let text: String
}

/// Reads meetings straight from disk, so it works even when Hearsay isn't running.
private struct MeetingLibrary {
    func summaries() throws -> [MeetingSummary] {
        if let data = try? Data(contentsOf: MeetingPaths.indexURL),
           let summaries = try? MeetingCoding.makeDecoder().decode([MeetingSummary].self, from: data) {
            return summaries.sorted { $0.startedAt > $1.startedAt }
        }
        // No index yet: scan the folders.
        let entries = (try? FileManager.default.contentsOfDirectory(at: MeetingPaths.rootDirectory, includingPropertiesForKeys: nil)) ?? []
        return entries
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
            .compactMap { try? document(id: $0).summary() }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func document(id: UUID) throws -> MeetingDocument {
        let data = try Data(contentsOf: MeetingPaths.documentURL(for: id))
        return try MeetingCoding.makeDecoder().decode(MeetingDocument.self, from: data)
    }

    /// "latest", a full UUID, or a unique id prefix.
    func document(matching reference: String) throws -> MeetingDocument {
        let summaries = try summaries()
        if reference.lowercased() == "latest" || reference.lowercased() == "last" {
            guard let latest = summaries.first else { throw CLIError("No meetings yet") }
            return try document(id: latest.id)
        }
        let needle = reference.lowercased()
        let matches = summaries.filter { $0.id.uuidString.lowercased().hasPrefix(needle) }
        switch matches.count {
        case 0: throw CLIError("No meeting matches '\(reference)'. Run 'hearsay meetings list'.")
        case 1: return try document(id: matches[0].id)
        default: throw CLIError("'\(reference)' matches \(matches.count) meetings; use more characters", exitCode: 64)
        }
    }
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

private struct DiagnosticLogReader {
    let logURL = appSupportDirectory().appendingPathComponent("debug.log")

    private let maxAge: TimeInterval = 24 * 60 * 60
    private let maxBytes = 1_000_000

    func snapshotText() throws -> String {
        let body = try prunedBody()
        let generatedAt = Self.isoFormatter().string(from: Date())
        return """
        # Hearsay diagnostic log
        # Generated: \(generatedAt)
        # Retention: last 24 hours, capped at 1000000 bytes
        # Privacy: metadata only; raw transcripts, audio, clipboard text, screenshots, and prompts are not recorded

        \(body)
        """
    }

    func writeSnapshotFile(text: String) throws -> URL {
        let timestamp = Self.isoFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Hearsay-Diagnostics-\(timestamp).log")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: logURL.path) {
            try FileManager.default.removeItem(at: logURL)
        }
    }

    private func prunedBody() throws -> String {
        guard FileManager.default.fileExists(atPath: logURL.path) else {
            return ""
        }

        let raw = try String(contentsOf: logURL, encoding: .utf8)
        let cutoff = Date().addingTimeInterval(-maxAge)
        let formatter = Self.isoFormatter()

        var lines: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            guard
                let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let timestamp = object["timestamp"] as? String,
                let date = formatter.date(from: timestamp),
                date >= cutoff
            else {
                continue
            }
            lines.append(line)
        }

        while byteCount(for: lines) > maxBytes, !lines.isEmpty {
            lines.removeFirst()
        }

        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private func byteCount(for lines: [String]) -> Int {
        lines.reduce(0) { $0 + $1.utf8.count + 1 }
    }

    private static func isoFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
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

    /// Every value of a repeatable option (`--alias a --alias b`).
    mutating func stringValues(after name: String) throws -> [String] {
        var values: [String] = []
        for (index, arg) in args.enumerated() where arg == name && !used.contains(index) {
            let valueIndex = index + 1
            guard valueIndex < args.count else {
                throw CLIError("\(name) requires a value", exitCode: 64)
            }
            used.insert(index)
            used.insert(valueIndex)
            values.append(args[valueIndex])
        }
        return values
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

    mutating func positionalArgument() -> String? {
        for (index, arg) in args.enumerated() where !used.contains(index) && !arg.hasPrefix("-") {
            used.insert(index)
            return arg
        }
        return nil
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
    try runProcess(executable, arguments, standardInput: nil)
}

private func runProcess(_ executable: String, _ arguments: [String], standardInput: Data?) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let inputPipe: Pipe?
    if standardInput != nil {
        inputPipe = Pipe()
        process.standardInput = inputPipe
    } else {
        inputPipe = nil
    }
    try process.run()
    if let standardInput, let inputPipe {
        inputPipe.fileHandleForWriting.write(standardInput)
        try? inputPipe.fileHandleForWriting.close()
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CLIError("\(URL(fileURLWithPath: executable).lastPathComponent) exited with \(process.terminationStatus)")
    }
}
