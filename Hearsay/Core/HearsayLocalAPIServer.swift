import Foundation
import Network
import os.log

private let apiLogger = Logger(subsystem: "com.swair.hearsay", category: "local-api")

protocol HearsayLocalAPIServerDelegate: AnyObject {
    @MainActor func localAPIState() -> DictationState
    @MainActor func startCallerDictation(request: DictationRequest) throws
    @MainActor func stopCallerDictation(requestId: UUID) throws
    @MainActor func cancelCallerDictation(requestId: UUID) throws
}

final class HearsayLocalAPIServer {
    weak var delegate: HearsayLocalAPIServerDelegate?

    private let queue = DispatchQueue(label: "com.swair.hearsay.local-api")
    private var listener: NWListener?
    private var eventStreams: [String: [NWConnection]] = [:]
    private var pendingResultResponses: [String: NWConnection] = [:]
    private var latestStates: [String: DictationState] = [:]
    private var completedResults: [String: DictationResult] = [:]

    init(delegate: HearsayLocalAPIServerDelegate) {
        self.delegate = delegate
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)

        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = listener.port {
                    self.writeDiscoveryFile(port: port)
                    apiLogger.info("Local API listening on 127.0.0.1:\(port.rawValue)")
                }
            case .failed(let error):
                apiLogger.error("Local API listener failed: \(error.localizedDescription)")
            case .cancelled:
                apiLogger.info("Local API listener cancelled")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        try? FileManager.default.removeItem(at: Constants.localAPIInfoURL)
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for streams in self.eventStreams.values {
                streams.forEach { $0.cancel() }
            }
            self.eventStreams.removeAll()
            for connection in self.pendingResultResponses.values {
                connection.cancel()
            }
            self.pendingResultResponses.removeAll()
        }
    }

    func publishState(requestId: UUID, state: DictationState) {
        let key = requestId.uuidString
        queue.async {
            self.latestStates[key] = state
            self.sendEvent(name: "state", object: ["requestId": key, "state": state.rawValue], requestId: key)
        }
    }

    func publishResult(_ result: DictationResult) {
        queue.async {
            self.completedResults[result.requestId] = result
            self.sendEvent(name: "result", object: result, requestId: result.requestId)
            self.sendPendingResultResponse(result)
            self.closeStreams(for: result.requestId)
        }
    }

    func publishError(requestId: UUID, message: String) {
        queue.async {
            let key = requestId.uuidString
            let result = DictationResult.failed(requestId: requestId, error: message)
            self.completedResults[key] = result
            self.sendEvent(name: "error", object: result, requestId: key)
            self.sendPendingResultResponse(result)
            self.closeStreams(for: key)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .cancelled = state, let connection else { return }
            self?.removeConnection(connection)
        }
        connection.start(queue: queue)
        receiveRequest(from: connection, buffer: Data())
    }

    private func receiveRequest(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                apiLogger.error("Local API receive failed: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if let request = HTTPRequest.parseIfComplete(nextBuffer) {
                self.handle(request, on: connection)
            } else if isComplete {
                self.sendError(connection, status: 400, code: "invalid_request", message: "Incomplete HTTP request")
            } else {
                self.receiveRequest(from: connection, buffer: nextBuffer)
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        let components = request.pathComponents

        if request.method == "GET", components == ["v1", "health"] {
            handleHealth(on: connection)
            return
        }

        if request.method == "GET", components == ["v1", "microphones"] {
            handleGetMicrophones(on: connection)
            return
        }

        if request.method == "GET", components == ["v1", "microphones", "current"] {
            handleGetCurrentMicrophone(on: connection)
            return
        }

        if request.method == "POST", components == ["v1", "microphones", "select"] {
            handleSelectMicrophone(request, on: connection)
            return
        }

        if request.method == "POST", components == ["v1", "dictations"] {
            handleStart(request, on: connection)
            return
        }

        if request.method == "POST", components.count == 4,
           components[0] == "v1", components[1] == "dictations", components[3] == "stop" {
            handleStop(requestId: components[2], on: connection)
            return
        }

        if request.method == "POST", components.count == 4,
           components[0] == "v1", components[1] == "dictations", components[3] == "cancel" {
            handleCancel(requestId: components[2], on: connection)
            return
        }

        if request.method == "GET", components.count == 4,
           components[0] == "v1", components[1] == "dictations", components[3] == "events" {
            handleEvents(requestId: components[2], on: connection)
            return
        }

        sendError(connection, status: 404, code: "not_found", message: "Unknown endpoint")
    }

    private func handleHealth(on connection: NWConnection) {
        Task { @MainActor in
            let state = delegate?.localAPIState() ?? .unavailable
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            sendJSON(connection, status: 200, object: [
                "ok": true,
                "app": "Hearsay",
                "version": version,
                "apiVersion": 1,
                "state": state.rawValue
            ] as [String: Any])
        }
    }

    private func handleGetMicrophones(on connection: NWConnection) {
        Task { @MainActor in
            let mgr = MicrophoneManager.shared
            mgr.refresh()
            let devices = mgr.availableDevices.map { dev -> [String: Any] in
                [
                    "uid": dev.uid,
                    "name": dev.name,
                    "isBuiltIn": dev.isBuiltIn,
                    "isActive": dev.uid == mgr.activeDevice?.uid,
                    "isSelected": dev.uid == mgr.selectedDeviceUID
                ]
            }
            var resp: [String: Any] = [
                "devices": devices,
                "selectedUID": mgr.selectedDeviceUID ?? NSNull()
            ]
            if let active = mgr.activeDevice {
                resp["activeDevice"] = [
                    "uid": active.uid,
                    "name": active.name,
                    "isBuiltIn": active.isBuiltIn
                ]
            }
            sendJSON(connection, status: 200, object: resp)
        }
    }

    private func handleGetCurrentMicrophone(on connection: NWConnection) {
        Task { @MainActor in
            let mgr = MicrophoneManager.shared
            mgr.refresh()
            var resp: [String: Any] = [
                "selectedUID": mgr.selectedDeviceUID ?? NSNull()
            ]
            if let active = mgr.activeDevice {
                resp["activeDevice"] = [
                    "uid": active.uid,
                    "name": active.name,
                    "isBuiltIn": active.isBuiltIn
                ]
            }
            sendJSON(connection, status: 200, object: resp)
        }
    }

    private struct SelectMicrophonePayload: Decodable {
        let uid: String?
    }

    private func handleSelectMicrophone(_ request: HTTPRequest, on connection: NWConnection) {
        let payload: SelectMicrophonePayload
        do {
            payload = try JSONDecoder().decode(SelectMicrophonePayload.self, from: request.body)
        } catch {
            sendError(connection, status: 400, code: "invalid_request", message: "Request body must be valid JSON")
            return
        }

        Task { @MainActor in
            let mgr = MicrophoneManager.shared
            mgr.refresh()
            let rawTarget = payload.uid?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let target = rawTarget, !target.isEmpty,
               target.lowercased() != "default",
               target.lowercased() != "system",
               target.lowercased() != "auto" {
                guard let matched = mgr.availableDevices.first(where: {
                    $0.uid == target || $0.name.localizedCaseInsensitiveCompare(target) == .orderedSame
                }) else {
                    sendError(connection, status: 404, code: "device_not_found", message: "Microphone not found: '\(target)'")
                    return
                }
                mgr.selectDevice(uid: matched.uid)
            } else {
                mgr.selectDevice(uid: nil)
            }

            var resp: [String: Any] = [
                "ok": true,
                "selectedUID": mgr.selectedDeviceUID ?? NSNull()
            ]
            if let active = mgr.activeDevice {
                resp["activeDevice"] = [
                    "uid": active.uid,
                    "name": active.name,
                    "isBuiltIn": active.isBuiltIn
                ]
            }
            sendJSON(connection, status: 200, object: resp)
        }
    }

    private func handleStart(_ request: HTTPRequest, on connection: NWConnection) {
        let payload: StartDictationPayload
        do {
            payload = try JSONDecoder().decode(StartDictationPayload.self, from: request.body)
        } catch {
            sendError(connection, status: 400, code: "invalid_request", message: "Request body must be valid JSON")
            return
        }

        guard payload.mode == nil || payload.mode == "returnToCaller" else {
            sendError(connection, status: 400, code: "invalid_request", message: "Only mode=returnToCaller is supported")
            return
        }

        let caller = payload.caller.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !caller.isEmpty else {
            sendError(connection, status: 400, code: "invalid_request", message: "caller is required")
            return
        }

        guard let providedRequestId = payload.requestId,
              let requestId = UUID(uuidString: providedRequestId) else {
            sendError(connection, status: 400, code: "invalid_request", message: "requestId must be a caller-generated UUID")
            return
        }

        let dictationRequest = DictationRequest(
            id: requestId,
            caller: caller,
            mode: .returnToCaller(requestId: requestId),
            createdAt: Date(),
            autoStop: payload.autoStop ?? false,
            metadata: payload.metadata ?? [:]
        )

        completedResults.removeValue(forKey: requestId.uuidString)
        latestStates.removeValue(forKey: requestId.uuidString)

        Task { @MainActor in
            do {
                try delegate?.startCallerDictation(request: dictationRequest)
                queue.async {
                    if let result = self.completedResults[requestId.uuidString] {
                        self.sendResultResponse(result, on: connection)
                    } else {
                        self.pendingResultResponses[requestId.uuidString] = connection
                    }
                }
            } catch {
                sendAPIError(error, on: connection)
            }
        }
    }

    private func handleStop(requestId: String, on connection: NWConnection) {
        guard let uuid = UUID(uuidString: requestId) else {
            sendError(connection, status: 400, code: "invalid_request", message: "requestId must be a UUID")
            return
        }

        if sendStopAcknowledgementForCompletedResult(requestId: uuid, on: connection) {
            return
        }

        Task { @MainActor in
            do {
                try delegate?.stopCallerDictation(requestId: uuid)
                sendJSON(connection, status: 200, object: [
                    "requestId": uuid.uuidString,
                    "status": "transcribing"
                ])
            } catch {
                if let apiError = error as? CallerDictationError, case .notFound = apiError {
                    queue.async {
                        if self.sendStopAcknowledgementForCompletedResult(requestId: uuid, on: connection) {
                            return
                        }
                        self.sendAPIError(error, on: connection)
                    }
                    return
                }
                sendAPIError(error, on: connection)
            }
        }
    }

    private func handleCancel(requestId: String, on connection: NWConnection) {
        guard let uuid = UUID(uuidString: requestId) else {
            sendError(connection, status: 400, code: "invalid_request", message: "requestId must be a UUID")
            return
        }

        Task { @MainActor in
            do {
                try delegate?.cancelCallerDictation(requestId: uuid)
                sendJSON(connection, status: 200, object: [
                    "requestId": uuid.uuidString,
                    "status": "cancelled"
                ])
            } catch {
                sendAPIError(error, on: connection)
            }
        }
    }

    private func handleEvents(requestId: String, on connection: NWConnection) {
        guard UUID(uuidString: requestId) != nil else {
            sendError(connection, status: 400, code: "invalid_request", message: "requestId must be a UUID")
            return
        }

        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Cache-Control: no-cache",
            "Connection: keep-alive",
            "",
            ""
        ].joined(separator: "\r\n")

        connection.send(content: Data(headers.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                apiLogger.error("Failed to open event stream: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            self.eventStreams[requestId, default: []].append(connection)
            if let result = self.completedResults[requestId] {
                self.sendEvent(name: result.status == "failed" ? "error" : "result", object: result, requestId: requestId)
                self.closeStreams(for: requestId)
            } else if let state = self.latestStates[requestId] {
                self.sendEvent(name: "state", object: ["requestId": requestId, "state": state.rawValue], requestId: requestId)
            }
        })
    }

    private func sendAPIError(_ error: Error, on connection: NWConnection) {
        if let apiError = error as? CallerDictationError {
            sendError(
                connection,
                status: apiError.httpStatus,
                code: apiError.apiCode,
                message: apiError.localizedDescription
            )
            return
        }

        sendError(connection, status: 500, code: "internal_error", message: error.localizedDescription)
    }

    @discardableResult
    private func sendStopAcknowledgementForCompletedResult(requestId: UUID, on connection: NWConnection) -> Bool {
        guard let result = completedResults[requestId.uuidString] else {
            return false
        }

        sendJSON(connection, status: 200, object: [
            "requestId": requestId.uuidString,
            "status": result.status
        ])
        return true
    }

    private func sendPendingResultResponse(_ result: DictationResult) {
        guard let connection = pendingResultResponses.removeValue(forKey: result.requestId) else {
            return
        }
        sendResultResponse(result, on: connection)
    }

    private func sendResultResponse(_ result: DictationResult, on connection: NWConnection) {
        do {
            let body = try JSONEncoder().encode(result)
            sendResponse(connection, status: 200, contentType: "application/json", body: body)
        } catch {
            sendError(connection, status: 500, code: "internal_error", message: "Failed to encode result")
        }
    }

    private func sendJSON(_ connection: NWConnection, status: Int, object: Any) {
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: object, options: [])
        } catch {
            sendError(connection, status: 500, code: "internal_error", message: "Failed to encode response")
            return
        }
        sendResponse(connection, status: status, contentType: "application/json", body: body)
    }

    private func sendError(_ connection: NWConnection, status: Int, code: String, message: String) {
        sendJSON(connection, status: status, object: [
            "error": code,
            "message": message
        ])
    }

    private func sendResponse(_ connection: NWConnection, status: Int, contentType: String, body: Data) {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        let header = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendEvent(name: String, object: Encodable, requestId: String) {
        guard let streams = eventStreams[requestId], !streams.isEmpty else {
            return
        }

        let payload: Data
        do {
            payload = try JSONEncoder().encode(AnyEncodable(object))
        } catch {
            apiLogger.error("Failed to encode SSE event: \(error.localizedDescription)")
            return
        }

        guard let json = String(data: payload, encoding: .utf8) else {
            return
        }

        let data = Data("event: \(name)\ndata: \(json)\n\n".utf8)
        for stream in streams {
            stream.send(content: data, completion: .contentProcessed { [weak self, weak stream] error in
                guard let self, let stream, error != nil else { return }
                self.removeConnection(stream)
            })
        }
    }

    private func closeStreams(for requestId: String) {
        guard let streams = eventStreams.removeValue(forKey: requestId) else {
            return
        }
        streams.forEach { $0.cancel() }
    }

    private func removeConnection(_ connection: NWConnection) {
        queue.async {
            for key in self.eventStreams.keys {
                self.eventStreams[key]?.removeAll { $0 === connection }
                if self.eventStreams[key]?.isEmpty == true {
                    self.eventStreams.removeValue(forKey: key)
                }
            }

            for key in self.pendingResultResponses.keys where self.pendingResultResponses[key] === connection {
                self.pendingResultResponses.removeValue(forKey: key)
            }
        }
    }

    private func writeDiscoveryFile(port: NWEndpoint.Port) {
        let payload: [String: Any] = [
            "host": "127.0.0.1",
            "port": Int(port.rawValue),
            "version": 1
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: Constants.appSupportDirectory, withIntermediateDirectories: true)
            try data.write(to: Constants.localAPIInfoURL, options: [.atomic])
            chmod(Constants.localAPIInfoURL.path, S_IRUSR | S_IWUSR)
        } catch {
            apiLogger.error("Failed to write local API discovery file: \(error.localizedDescription)")
        }
    }
}

private struct StartDictationPayload: Decodable {
    let caller: String
    let mode: String?
    let requestId: String?
    let autoStop: Bool?
    let metadata: [String: String]?
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var pathComponents: [String] {
        path.split(separator: "?").first?
            .split(separator: "/")
            .map(String.init) ?? []
    }

    static func parseIfComplete(_ data: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            return nil
        }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }

        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            headers[parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else {
            return nil
        }

        return HTTPRequest(
            method: requestParts[0],
            path: requestParts[1],
            headers: headers,
            body: data[bodyStart..<(bodyStart + contentLength)]
        )
    }
}

private struct AnyEncodable: Encodable {
    private let encodeClosure: (Encoder) throws -> Void

    init(_ value: Encodable) {
        encodeClosure = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}
