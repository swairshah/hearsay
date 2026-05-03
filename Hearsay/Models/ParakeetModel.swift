import Foundation

/// Known NVIDIA Parakeet Core ML bundles supported through FluidAudio.
enum ParakeetModel: String, CaseIterable {
    case englishV2 = "parakeet-tdt-0.6b-v2-coreml"
    case multilingualV3 = "parakeet-tdt-0.6b-v3-coreml"

    var identifier: String { rawValue }

    var displayName: String {
        switch self {
        case .englishV2: return "Parakeet English (v2)"
        case .multilingualV3: return "Parakeet Multilingual (v3)"
        }
    }

    var description: String {
        switch self {
        case .englishV2: return "Fast Core ML transcription for English"
        case .multilingualV3: return "Fast Core ML transcription with multilingual support"
        }
    }

    var estimatedSize: Int64 {
        650_000_000
    }

    var cacheDirectoryNames: [String] {
        let fluidAudioFolderName = rawValue.replacingOccurrences(of: "-coreml", with: "")
        return [rawValue, fluidAudioFolderName]
    }

    static func containsCompiledModel(in directory: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else {
            return false
        }

        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }

        for case let url as URL in enumerator {
            if url.pathExtension == "mlmodelc" || url.lastPathComponent.hasSuffix(".mlmodelc") {
                return true
            }
        }

        return false
    }

    func cachedDirectories() -> [URL] {
        let fileManager = FileManager.default
        var directories: [URL] = []

        for root in Self.candidateRoots() {
            for vendorDirectory in ["fluidaudio/Models", "FluidAudio/Models"] {
                let base = root.appendingPathComponent(vendorDirectory, isDirectory: true)
                for directoryName in cacheDirectoryNames {
                    let direct = base.appendingPathComponent(directoryName, isDirectory: true)
                    directories.append(direct)
                }

                guard let items = try? fileManager.contentsOfDirectory(
                    at: base,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: .skipsHiddenFiles
                ) else {
                    continue
                }

                for item in items where cacheDirectoryNames.contains(where: { item.lastPathComponent.hasPrefix($0) }) {
                    directories.append(item)
                }
            }
        }

        return directories
    }

    private static func candidateRoots() -> [URL] {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let xdgCache = environment["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let userCache = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".cache", isDirectory: true)

        return [xdgCache, Constants.fluidAudioCacheDirectory, appSupport, userCache].compactMap { $0 }
    }
}
