import XCTest
@testable import Shiyi

final class VoiceTranscriptArchiveTests: XCTestCase {
    @MainActor
    func testAtomicSessionSurvivesRestartAndDraftRevisionsDoNotDuplicate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShiyiArchiveTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = VoiceTranscriptArchive(directory: directory)
        let id = archive.begin(source: .english, target: .simplifiedChinese)
        let captionID = UUID()
        archive.record(VoiceCaption(id: captionID, original: "Meeting"), sessionID: id)
        archive.record(VoiceCaption(id: captionID, original: "Meeting starts at nine.", translation: "会议九点开始。"), sessionID: id)
        archive.end(id)
        archive.flush()
        let restarted = VoiceTranscriptArchive(directory: directory)
        await restarted.refresh()
        XCTAssertEqual(restarted.sessions.count, 1)
        let result = try await restarted.load(id)
        XCTAssertEqual(result.source, .english)
        XCTAssertEqual(result.target, .simplifiedChinese)
        XCTAssertNotNil(result.endedAt)
        XCTAssertEqual(result.captions.count, 1)
        XCTAssertEqual(result.captions.first?.original, "Meeting starts at nine.")
        XCTAssertEqual(result.captions.first?.translation, "会议九点开始。")
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(id.uuidString).appendingPathExtension("json").path)
        XCTAssertEqual((permissions[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    @MainActor
    func testFullSessionKeepsMoreThanScreenHistoryAndLateResultKeepsOriginalSession() async throws {
        let archive = VoiceTranscriptArchive(directory: nil)
        let first = archive.begin(source: .english, target: .german)
        var captions: [VoiceCaption] = []
        for index in 0..<150 {
            let caption = VoiceCaption(id: UUID(), original: "Sentence \(index)", translation: "Satz \(index)")
            captions.append(caption)
            archive.record(caption, sessionID: first)
        }
        archive.end(first)
        let second = archive.begin(source: .japanese, target: .english)
        archive.record(VoiceCaption(id: UUID(), original: "こんにちは", translation: "Hello"), sessionID: second)
        captions[0].translation = "Late correction"
        archive.record(captions[0], sessionID: first)
        let originalSession = try await archive.load(first)
        let nextSession = try await archive.load(second)
        XCTAssertEqual(originalSession.captions.count, 150)
        XCTAssertEqual(originalSession.captions[0].translation, "Late correction")
        XCTAssertEqual(nextSession.captions.count, 1)
        XCTAssertEqual(nextSession.source, .japanese)
        XCTAssertTrue(originalSession.markdown.contains("Sentence 149"))
        XCTAssertTrue(originalSession.markdown.contains("Late correction"))
    }
    func testMarkdownIncludesUntranslatedOriginalWithExplicitStatus() {
        var session = VoiceTranscriptSession(source: .german, target: .simplifiedChinese)
        session.upsert(VoiceCaption(id: UUID(), original: "Nicht fertig", failure: "已取消"))
        XCTAssertTrue(session.markdown.contains("德语 → 简体中文"))
        XCTAssertTrue(session.markdown.contains("Nicht fertig"))
        XCTAssertTrue(session.markdown.contains("未完成翻译：已取消"))
    }
}
