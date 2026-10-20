import XCTest
#if compiler(>=6.2)
import Speech
import AVFoundation
@testable import Shiyi

final class VoiceAudioIntegrationTests: XCTestCase {
    func testRecordedAudioThroughLocalRecognitionAndTranslation() async throws {
        guard let path = ProcessInfo.processInfo.environment["SHIYI_VOICE_TEST_FILE"] else {
            throw XCTSkip("Opt-in: provide a local speech fixture and prepared local translation model.")
        }
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else { throw XCTSkip("Requires SpeechAnalyzer") }
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        let locale = try XCTUnwrap(supported)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        _ = try await AssetInventory.reserve(locale: locale)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let resultTask = Task { () throws -> String in
            var collected = ""
            for try await result in transcriber.results { collected += String(result.text.characters) }
            return collected
        }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        let text = try await resultTask.value
        XCTAssertTrue(text.lowercased().contains("meeting"), text)
        let translated = try await LocalVoiceClient().translate(text, source: .english, target: .simplifiedChinese)
        XCTAssertTrue(translated.contains("会议"), translated)
        XCTAssertFalse(translated.isEmpty)
    }
}
#endif
