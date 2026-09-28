import XCTest
import CryptoKit
@testable import SpatialCore

final class DiagnosticTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ProbeDiagnosticTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }
        return url
    }
    private func drain(_ journal: DiagnosticJournal) {
        let done = expectation(description:"journal drained")
        journal.flush { done.fulfill() }; wait(for:[done],timeout:10)
    }
    private func row(_ journal: DiagnosticJournal,_ stream: String) throws -> [String:Any] {
        let text = try String(contentsOf:journal.directory.appendingPathComponent(stream+".jsonl"),encoding:.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with:Data(text.split(separator:"\n")[0].utf8)) as? [String:Any])
    }
    private func observation() -> DepthObservation {
        .init(width:2,height:2,depth:[1,.nan,-1,.infinity],confidence:[2,1,0,255],intrinsics:.init(fx:2,fy:2,cx:0.5,cy:0.5,width:2,height:2),
              pose:.init(position:V3(0,1.3,0)),timestamp:12,frameID:18,epoch:3)
    }
    func testLaunchCreatesManifestBeforeCameraOrPermission() throws {
        let journal = DiagnosticJournal(root:try root(),metadata:["source":"synthetic","build":"test"])
        drain(journal)
        let data = try Data(contentsOf:journal.directory.appendingPathComponent("manifest.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual(object["source"] as? String,"synthetic")
        XCTAssertNotNil(object["launchUptime"]); XCTAssertNotNil(object["launchedAt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath:journal.directory.appendingPathComponent("status.json").path))
        XCTAssertEqual(journal.status().written.values.reduce(0,+),0)
    }
    func testLaunchesNeverOverwriteHistoryAndHistoryCanBeExported() throws {
        let base = try root(),first = DiagnosticJournal(root:base,metadata:["source":"synthetic"])
        first.submit(.events) { .init(json:Data("{\"name\":\"one\"}".utf8)) }; drain(first)
        let second = DiagnosticJournal(root:base,metadata:["source":"synthetic"]); drain(second)
        XCTAssertNotEqual(first.directory,second.directory)
        let done = expectation(description:"history export")
        second.export(runID:first.directory.lastPathComponent,to:base.appendingPathComponent("exports")) { result in
            if case .success(let url) = result { XCTAssertTrue(FileManager.default.fileExists(atPath:url.appendingPathComponent("events.jsonl").path)) }
            else { XCTFail("Historical export failed") }
            done.fulfill()
        }
        wait(for:[done],timeout:10)
        XCTAssertEqual(try row(first,"events")["sequence"] as? Int,1)
    }
    func testBinaryAttachmentRoundTripsAndPreservesDepthBitsWithoutRGB() throws {
        let journal = DiagnosticJournal(root:try root(),metadata:["source":"synthetic"]),o = observation()
        let raw = try DepthFrameCodec.encode(o,parameters:.init(),parameterVersion:4,priors:[],directionStable:false,source:"synthetic")
        journal.submit(.analysis) { .init(json:Data("{\"frameID\":18}".utf8),binary:raw) }; drain(journal)
        let ref = try XCTUnwrap(try row(journal,"analysis")["attachment"] as? [String:Any])
        let data = try Data(contentsOf:journal.directory.appendingPathComponent(try XCTUnwrap(ref["file"] as? String)))
        let compressed = Int(data.withUnsafeBytes { UInt32(littleEndian:$0.loadUnaligned(as:UInt32.self)) })
        let restored = try (data.subdata(in:8..<(8+compressed)) as NSData).decompressed(using:.zlib) as Data
        XCTAssertEqual(restored,raw)
        XCTAssertEqual(ref["sha256"] as? String,SHA256.hash(data:raw).map { String(format:"%02x",$0) }.joined())
        let headerSize = Int(raw.withUnsafeBytes { UInt32(littleEndian:$0.loadUnaligned(as:UInt32.self)) })
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with:raw.subdata(in:4..<(4+headerSize))) as? [String:Any])
        XCTAssertEqual(header["source"] as? String,"synthetic"); XCTAssertEqual(header["confidenceBytes"] as? Int,4)
        let start = 4+headerSize
        for i in o.depth.indices {
            let bits = raw.withUnsafeBytes { UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:start+i*4,as:UInt32.self)) }
            XCTAssertEqual(bits,o.depth[i].bitPattern)
        }
        XCTAssertEqual(Array(raw.suffix(4)),o.confidence)
        XCTAssertFalse(header.keys.contains("capturedImage")); XCTAssertFalse(header.keys.contains("rgb"))
        // A portable synthetic fixture for validating the Python raw-DEFLATE reader.
        if let destination = ProcessInfo.processInfo.environment["DIAG_FIXTURE_ROOT"] {
            let target = URL(fileURLWithPath:destination).appendingPathComponent("synthetic-launch",isDirectory:true)
            try? FileManager.default.removeItem(at:target)
            try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
            try FileManager.default.copyItem(at:journal.directory,to:target)
        }
    }
    func testMissingConfidenceIsNotFabricated() throws {
        var o = observation(); o.confidence = nil
        let data = try DepthFrameCodec.encode(o,parameters:.init(),parameterVersion:0,priors:[],directionStable:false,source:"synthetic")
        let size = Int(data.withUnsafeBytes { UInt32(littleEndian:$0.loadUnaligned(as:UInt32.self)) })
        let h = try XCTUnwrap(JSONSerialization.jsonObject(with:data.subdata(in:4..<(4+size))) as? [String:Any])
        XCTAssertEqual(h["confidenceBytes"] as? Int,0); XCTAssertEqual(data.count,4+size+16)
    }
    func testDepthQualityAccountsForInvalidPixelsAndConfidence() {
        let stats = DepthStatistics(observation(),parameters:.init())
        XCTAssertEqual(stats.nonFinite,2); XCTAssertEqual(stats.nonPositive,1)
        XCTAssertEqual(stats.acceptedHighConfidence,1); XCTAssertEqual(stats.minimum,1)
        XCTAssertEqual(stats.low,1); XCTAssertEqual(stats.medium,1); XCTAssertEqual(stats.high,1); XCTAssertEqual(stats.unrecognizedConfidence,1)
        var o = observation(); o.confidence = nil
        XCTAssertFalse(DepthStatistics(o,parameters:.init()).confidenceAvailable)
        XCTAssertEqual(DepthStatistics(o,parameters:.init()).acceptedHighConfidence,0)
    }
    func testBoundedAdmissionRecordsDropsAndReservesAnEventSlot() throws {
        var limits = DiagnosticLimits(); limits.maximumPending = 3; limits.reservedEvents = 1
        let journal = DiagnosticJournal(root:try root(),metadata:["source":"synthetic"],limits:limits)
        let entered = DispatchSemaphore(value:0),release = DispatchSemaphore(value:0)
        XCTAssertTrue(journal.submit(.analysis) { entered.signal(); release.wait(); return .init(json:Data("{}".utf8)) })
        XCTAssertEqual(entered.wait(timeout:.now()+5),.success)
        XCTAssertTrue(journal.submit(.capture) { .init(json:Data("{}".utf8)) })
        XCTAssertFalse(journal.submit(.capture) { XCTFail("Rejected work must not execute"); return .init(json:Data("{}".utf8)) })
        XCTAssertTrue(journal.submit(.events) { .init(json:Data("{}".utf8)) })
        XCTAssertFalse(journal.submit(.events) { .init(json:Data("{}".utf8)) })
        release.signal(); drain(journal)
        XCTAssertEqual(journal.status().droppedTotal,2); XCTAssertEqual(journal.status().pending,0)
        XCTAssertEqual(journal.status().written["events"],1)
    }
    func testReservedByteBudgetProtectsEventsWhenMeshQueueFillsMemory() throws {
        var limits = DiagnosticLimits(); limits.maximumPendingBytes = 8192; limits.reservedEventBytes = 1024
        let journal = DiagnosticJournal(root:try root(),metadata:["source":"synthetic"],limits:limits)
        let entered = DispatchSemaphore(value:0),release = DispatchSemaphore(value:0)
        XCTAssertTrue(journal.submit(.mesh,estimatedBytes:7168) { entered.signal(); release.wait(); return .init(json:Data("{}".utf8)) })
        XCTAssertEqual(entered.wait(timeout:.now()+5),.success)
        XCTAssertFalse(journal.submit(.mesh,estimatedBytes:1) { XCTFail("Must not consume event bytes"); return .init(json:Data()) })
        XCTAssertTrue(journal.submit(.events,estimatedBytes:1024) { .init(json:Data("{}".utf8)) })
        release.signal(); drain(journal)
        XCTAssertEqual(journal.status().written["events"],1); XCTAssertEqual(journal.status().maximumPendingBytesObserved,8192)
    }
    func testMemoryAdmissionRejectsOversizeWithoutEncoding() throws {
        var limits = DiagnosticLimits(); limits.maximumPendingBytes = 1024
        let journal = DiagnosticJournal(root:try root(),metadata:["source":"synthetic"],limits:limits)
        XCTAssertFalse(journal.submit(.analysis,estimatedBytes:2048) { XCTFail("Must not allocate payload"); return .init(json:Data()) })
        drain(journal); XCTAssertEqual(journal.status().dropped["analysis"],1)
    }
    func testRunQuotaStopsRecordingWithoutDeletingEvidence() throws {
        var limits = DiagnosticLimits(); limits.runBytes = 10
        let journal = DiagnosticJournal(root:try root(),metadata:["source":"synthetic"],limits:limits)
        journal.submit(.events) { .init(json:Data("{}".utf8)) }; drain(journal)
        XCTAssertTrue(journal.status().limitReached)
        XCTAssertTrue(FileManager.default.fileExists(atPath:journal.directory.appendingPathComponent("manifest.json").path))
        XCTAssertFalse(journal.submit(.analysis) { .init(json:Data("{}".utf8)) })
        drain(journal)
        let status = try JSONDecoder().decode(DiagnosticStatus.self,from:Data(contentsOf:journal.directory.appendingPathComponent("status.json")))
        XCTAssertEqual(status.droppedTotal,2)
    }
    func testGlobalQuotaCountsPreviousLaunches() throws {
        let base = try root(); try Data(repeating:1,count:8000).write(to:base.appendingPathComponent("previous-data.bin"))
        var limits = DiagnosticLimits(); limits.totalBytes = 8000
        let journal = DiagnosticJournal(root:base,metadata:["source":"synthetic"],limits:limits)
        journal.submit(.events) { .init(json:Data("{}".utf8)) }; drain(journal)
        XCTAssertTrue(journal.status().limitReached)
        XCTAssertEqual(try Data(contentsOf:base.appendingPathComponent("previous-data.bin")).count,8000)
    }
    func testBinarySegmentsRotateWithoutChangingJSONReferences() throws {
        var limits = DiagnosticLimits(); limits.segmentBytes = 1
        let journal = DiagnosticJournal(root:try root(),metadata:["source":"synthetic"],limits:limits)
        for _ in 0..<3 { journal.submit(.analysis) { .init(json:Data("{}".utf8),binary:Data("depth confidence test".utf8)) } }
        drain(journal)
        for i in 0..<3 { XCTAssertTrue(FileManager.default.fileExists(atPath:journal.directory.appendingPathComponent(String(format:"data-%05d.bin",i)).path)) }
        XCTAssertEqual(journal.status().written["analysis"],3)
    }
    func testEncodingFailureIsVisibleAndDoesNotCrashProducer() throws {
        let journal = DiagnosticJournal(root:try root(),metadata:["source":"synthetic"])
        journal.submit(.analysis) { throw CocoaError(.coderInvalidValue) }; drain(journal)
        XCTAssertNotNil(journal.status().error); XCTAssertEqual(journal.status().failed["analysis"],1)
    }
    func testNonFiniteTelemetryIsExplicitValidJSON() throws {
        struct Values: Encodable { let a = Float.nan,b = Double.infinity }
        let data = try DiagnosticJSON.encode(Values())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:String])
        XCTAssertEqual(object["a"],"nan"); XCTAssertEqual(object["b"],"+inf")
    }
    func testExportCannotEscapeDiagnosticRoot() throws {
        let journal = DiagnosticJournal(root:try root(),metadata:["source":"synthetic"]),done = expectation(description:"invalid export")
        journal.export(runID:"../elsewhere",to:journal.root.appendingPathComponent("export")) { result in
            if case .success = result { XCTFail("Path traversal accepted") }; done.fulfill()
        }
        wait(for:[done],timeout:5)
    }
    func testAnalysisExplainsMissingEvidenceWithoutChangingSafetyDecision() {
        let o = observation(),analyzer = SpatialAnalyzer()
        let result = analyzer.analyze(o,priors:[],parameters:.init(),parameterVersion:0,directionStable:false,source:"synthetic")
        XCTAssertEqual(result.diagnostics?.modelBlockReasons,["ground_fit_failed"])
        XCTAssertEqual(result.diagnostics?.sampledPoints,1)
        XCTAssertNil(result.surfaceModel); XCTAssertTrue(result.segments.isEmpty)
    }
}
