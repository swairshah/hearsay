import XCTest
@testable import Hearsay

final class ModelDownloaderTests: XCTestCase {
    private var originalSelectedModelRawValue: String?

    override func setUp() {
        super.setUp()
        originalSelectedModelRawValue = UserDefaults.standard.string(forKey: ModelDownloader.selectedModelDefaultsKey)
    }

    override func tearDown() {
        if let originalSelectedModelRawValue {
            UserDefaults.standard.set(originalSelectedModelRawValue, forKey: ModelDownloader.selectedModelDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ModelDownloader.selectedModelDefaultsKey)
        }
        super.tearDown()
    }

    func testWhisperTinyMetadata() {
        let model = ModelDownloader.Model.whisperTinyEn

        XCTAssertEqual(model.backend, .whisperKit)
        XCTAssertEqual(model.whisperVariant, "openai_whisper-tiny.en")
        XCTAssertEqual(model.whisperCachePathComponents, ["argmaxinc", "whisperkit-coreml", "openai_whisper-tiny.en"])
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertGreaterThan(model.estimatedSize, 0)
    }

    func testQwenSmallMetadata() {
        let model = ModelDownloader.Model.small

        XCTAssertEqual(model.backend, .qwenASR)
        XCTAssertEqual(model.huggingFaceId, "Qwen/Qwen3-ASR-0.6B")
        XCTAssertFalse(model.files.isEmpty)
        XCTAssertNil(model.whisperVariant)
    }

    func testSelectedModelPreferenceRoundTrip() {
        let downloader = ModelDownloader.shared
        downloader.setSelectedModelPreference(.whisperSmallEn)

        XCTAssertEqual(downloader.selectedModelPreference(), .whisperSmallEn)
    }

    func testWhisperInstalledDetectionForCurrentCacheLayout() throws {
        let model: ModelDownloader.Model = .whisperTinyEn
        guard let components = model.whisperCachePathComponents else {
            XCTFail("Expected whisper cache path components")
            return
        }

        let modelPath = components.reduce(Constants.whisperModelsRootDirectory) { partialURL, component in
            partialURL.appendingPathComponent(component, isDirectory: true)
        }

        let fileManager = FileManager.default
        let existedBefore = fileManager.fileExists(atPath: modelPath.path)

        if !existedBefore {
            try fileManager.createDirectory(at: modelPath, withIntermediateDirectories: true)
        }

        defer {
            if !existedBefore {
                try? fileManager.removeItem(at: modelPath)
            }
        }

        XCTAssertTrue(ModelDownloader.shared.isModelInstalled(model))
    }
}
