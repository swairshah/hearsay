import Foundation
import os.log

actor ParakeetClient {
    static let shared = ParakeetClient()

    private struct HelperRequest: Codable {
        let id: Int
        let command: String
        let model: String?
        let audioPath: String?
    }

    private struct HelperResponse: Codable {
        let id: Int
        let ok: Bool
        let text: String?
        let error: String?
    }

    private let connection = HelperProcessConnection(name: "parakeet")
    private var nextRequestID = 1
    private var currentModel: ParakeetModel?
    private let logger = Logger(subsystem: "com.swair.hearsay", category: "parakeet")

    func isModelAvailable(_ model: ParakeetModel) -> Bool {
        if currentModel == model, connection.isRunning {
            return true
        }

        for directory in model.cachedDirectories() where ParakeetModel.containsCompiledModel(in: directory) {
            logger.notice("Found Parakeet cache at \(directory.path)")
            return true
        }

        return false
    }

    func ensureLoaded(_ model: ParakeetModel, progress: @escaping (Progress) -> Void = { _ in }) async throws {
        if currentModel == model, connection.isRunning {
            return
        }

        let startedAt = Date()
        logger.notice("Starting Parakeet helper load variant=\(model.identifier)")

        let loadProgress = Progress(totalUnitCount: 100)
        loadProgress.completedUnitCount = 1
        progress(loadProgress)

        let pollTask = Task {
            while loadProgress.completedUnitCount < 95 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                for directory in model.cachedDirectories() {
                    guard let size = Self.directorySize(directory) else {
                        continue
                    }

                    let targetSize = Double(model.estimatedSize)
                    let fraction = max(0.0, min(1.0, Double(size) / targetSize))
                    loadProgress.completedUnitCount = Int64(5 + fraction * 90)
                    progress(loadProgress)
                    break
                }

                if Task.isCancelled {
                    break
                }
            }
        }
        defer { pollTask.cancel() }

        _ = try await send(command: "load", model: model)
        currentModel = model

        loadProgress.completedUnitCount = 100
        progress(loadProgress)
        logger.notice("Parakeet helper load completed in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
    }

    func prewarm(_ model: ParakeetModel) async throws {
        try await ensureLoaded(model)
        let startedAt = Date()
        logger.notice("Starting Parakeet helper prewarm variant=\(model.identifier)")
        _ = try await send(command: "prewarm", model: model)
        logger.notice("Parakeet helper prewarm finished in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
    }

    func transcribe(_ url: URL) async throws -> String {
        guard let currentModel else {
            throw SpeechTranscriptionError.failed("Parakeet not initialized")
        }

        let startedAt = Date()
        logger.notice("Transcribing with Parakeet helper file=\(url.lastPathComponent)")
        let response = try await send(command: "transcribe", model: currentModel, audioURL: url)
        logger.info("Parakeet helper transcription finished in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
        return (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func deleteCaches(_ model: ParakeetModel) async throws {
        var removedAny = false
        for directory in model.cachedDirectories() where FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
            removedAny = true
        }

        if removedAny, currentModel == model {
            connection.stop()
            currentModel = nil
        }
    }

    private func send(command: String, model: ParakeetModel, audioURL: URL? = nil) async throws -> HelperResponse {
        let requestID = nextRequestID
        nextRequestID += 1

        let request = HelperRequest(
            id: requestID,
            command: command,
            model: model.rawValue,
            audioPath: audioURL?.path
        )

        let responseData = try await connection.roundTrip(try JSONEncoder().encode(request))

        let response = try JSONDecoder().decode(HelperResponse.self, from: responseData)
        guard response.id == requestID else {
            throw SpeechTranscriptionError.failed("Parakeet helper returned an out-of-order response")
        }

        guard response.ok else {
            throw SpeechTranscriptionError.failed(response.error ?? "Parakeet helper failed")
        }

        return response
    }

    private static func directorySize(_ directory: URL) -> UInt64? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else {
            return nil
        }

        var total: UInt64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            total &+= UInt64(values.fileSize ?? 0)
        }

        return total
    }
}
