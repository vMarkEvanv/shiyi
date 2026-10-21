import XCTest
@testable import Shiyi

private final class EnergyHTTPStub: URLProtocol {
    static var requests: [(String, [String: Any])] = []
    static var available = true
    static var observed: XCTestExpectation?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        let path = request.url!.path
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.requests.append((path, body))
        let status = path == "/api/version" && !Self.available ? 503 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"version":"test","done":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
        if path == "/api/generate" || !Self.available { Self.observed?.fulfill() }
    }
    override func stopLoading() {}
}

final class VoiceEnergyTests: XCTestCase {
    @MainActor
    private func model() -> LocalVoiceModel {
        EnergyHTTPStub.requests = []; EnergyHTTPStub.available = true; EnergyHTTPStub.observed = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EnergyHTTPStub.self]
        return LocalVoiceModel(session: URLSession(configuration: config))
    }
    @MainActor
    func testCheckingInstallationNeverStartsNetworkService() async {
        let model = model()
        await model.refresh()
        XCTAssertTrue(EnergyHTTPStub.requests.isEmpty)
        model.shutdown()
    }
    @MainActor
    func testRestartingListeningCancelsPendingUnload() async throws {
        let model = model()
        model.unload(delayNanoseconds: 50_000_000)
        model.retainWhileListening()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(EnergyHTTPStub.requests.isEmpty)
        model.shutdown()
    }
    @MainActor
    func testIdleReleaseUnloadsModelWithoutStartingAnotherServer() async {
        let model = model()
        let released = expectation(description: "model released")
        EnergyHTTPStub.observed = released
        model.unload(delayNanoseconds: 0)
        await fulfillment(of: [released], timeout: 2)
        XCTAssertEqual(EnergyHTTPStub.requests.map(\.0), ["/api/version", "/api/generate"])
        XCTAssertEqual(EnergyHTTPStub.requests.last?.1["keep_alive"] as? Int, 0)
        model.shutdown()
    }
    @MainActor
    func testIdleReleaseDoesNotStartAnAbsentServer() async {
        let model = model()
        EnergyHTTPStub.available = false
        let checked = expectation(description: "existing service checked")
        EnergyHTTPStub.observed = checked
        model.unload(delayNanoseconds: 0)
        await fulfillment(of: [checked], timeout: 2)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(EnergyHTTPStub.requests.map(\.0), ["/api/version"])
        model.shutdown()
    }
    @MainActor
    func testOptInOwnedServiceStopsAndCanRestart() async throws {
        guard ProcessInfo.processInfo.environment["SHIYI_ENERGY_BENCH"] == "1" else { throw XCTSkip("Opt-in local model process lifecycle") }
        var probe = URLRequest(url: LocalVoiceClient.base.appendingPathComponent("api/version")); probe.timeoutInterval = 0.5
        if let (_, response) = try? await URLSession.shared.data(for: probe), (response as? HTTPURLResponse)?.statusCode == 200 {
            throw XCTSkip("An existing local service is in use; do not take over its lifecycle")
        }
        let model = LocalVoiceModel()
        defer { model.shutdown() }
        await model.refresh()
        guard model.ready else { throw XCTSkip("Requires installed local model") }
        try await model.warmUp()
        let translation = try await LocalVoiceClient().translate("The meeting starts at nine.", source: .english, target: .simplifiedChinese)
        XCTAssertTrue(translation.contains("会议"))
        model.unload(delayNanoseconds: 0)
        var stopped = false
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if (try? await URLSession.shared.data(for: probe)) == nil { stopped = true; break }
        }
        XCTAssertTrue(stopped, "Owned inference service must exit after idle release")
        try await model.warmUp()
        let (_, restarted) = try await URLSession.shared.data(for: probe)
        XCTAssertEqual((restarted as? HTTPURLResponse)?.statusCode, 200)
        print("ENERGY_BENCH owned_service_stopped=true restarted=true")
    }

    func testOfflineInstallationCheckRequiresEveryBlob() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiyiInstallationTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime")
        let manifest = root.appendingPathComponent("VoiceModels/manifests/registry.ollama.ai/library/translategemma/4b")
        let blobs = root.appendingPathComponent("VoiceModels/blobs")
        for directory in [runtime, manifest.deletingLastPathComponent(), blobs] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let executable = runtime.appendingPathComponent("ollama")
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let digest = String(repeating: "a", count: 64)
        let blob = blobs.appendingPathComponent("sha256-" + digest)
        try Data("abc".utf8).write(to: blob)
        let item: [String: Any] = ["digest": "sha256:" + digest, "size": 3]
        try JSONSerialization.data(withJSONObject: ["config": item, "layers": [item]]).write(to: manifest)
        XCTAssertTrue(VoiceModelInstallation.isComplete(root: root, runtime: runtime))
        try Data("x".utf8).write(to: blob)
        XCTAssertFalse(VoiceModelInstallation.isComplete(root: root, runtime: runtime))
        try FileManager.default.removeItem(at: blob)
        XCTAssertFalse(VoiceModelInstallation.isComplete(root: root, runtime: runtime))
    }
}
