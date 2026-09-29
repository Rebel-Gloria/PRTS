#if PRTS_DEV_CAPTURE
import AVFoundation
import CoreVideo
import Foundation
import Testing
import SpatialCore
@testable import PRTS

/// All input pixels/depth are synthetic; these tests do not validate ARKit or real camera recording.
@Suite(.serialized) struct DevCaptureTests {
    private func waitIdle(_ recorder: DevCaptureRecorder) async throws {
        for _ in 0..<1000 {
            if !recorder.status().busy { return }
            try await Task.sleep(for:.milliseconds(10))
        }
        Issue.record("Recorder failed to drain within 10 seconds")
    }
    private func stop(_ recorder: DevCaptureRecorder) async {
        await withCheckedContinuation { continuation in recorder.stop { continuation.resume() } }
    }
    private func packet(_ id: UInt64,_ time: Double) throws -> DevCaptureRecorder.Packet {
        var pixel: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil,64,48,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&pixel) == kCVReturnSuccess)
        let image = try #require(pixel)
        CVPixelBufferLockBaseAddress(image,[])
        if let base = CVPixelBufferGetBaseAddress(image) { memset(base,100,CVPixelBufferGetBytesPerRow(image)*48) }
        CVPixelBufferUnlockBaseAddress(image,[])
        let result = AnalysisResult(epoch:1,frameID:id,timestamp:time,parameters:.init(),status:"synthetic",source:"synthetic_test")
        var packet = DevCaptureRecorder.Packet(image:image,timestamp:time,epoch:1,capture:nil,result:result,path:.init(reason:"synthetic"),source:"synthetic_test")
        packet.observation = DepthObservation(width:2,height:2,depth:[1,.nan,.infinity,2],confidence:[2,0,0,1],
            intrinsics:.init(fx:2,fy:2,cx:1,cy:1,width:2,height:2),pose:.init(),timestamp:time,frameID:id,epoch:1)
        return packet
    }
    @Test func disabledCreatesNoFilesAndStopIsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let recorder = DevCaptureRecorder(root:root)
        recorder.submit(try packet(1,10))
        #expect(!recorder.status().enabled)
        await stop(recorder); await stop(recorder)
        #expect(!FileManager.default.fileExists(atPath:root.path))
    }
    @Test func uncalibratedModelOutputIsSavedWithoutInventedMetricDepth() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let recorder = DevCaptureRecorder(root:root); recorder.enable()
        var input = try packet(1,10)
        input.observation = nil
        input.relative = [1,Float(bitPattern:0x7fc00001),.infinity,0]
        input.model = .init(width:2,height:2,calibration:nil,provisionalFit:nil,scaleDecision:.init(),scaleSamples:[],
            groundReference:.init(mode:"invalid",reason:"synthetic"),timings:[:],status:"synthetic uncalibrated")
        recorder.submit(input); try await waitIdle(recorder); await stop(recorder)
        let folder = try #require(FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).first)
        let line = try String(contentsOf:folder.appendingPathComponent("samples.jsonl"),encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
        let row = try #require(JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any])
        #expect(row["depth"] == nil)
        let relative = try #require(row["relative"] as? [String:Any])
        let filename = try #require(relative["file"] as? String)
        let raw = try (Data(contentsOf:folder.appendingPathComponent(filename)) as NSData).decompressed(using:.zlib) as Data
        #expect(raw.count == 16)
        #expect(raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:4,as:UInt32.self).littleEndian } == 0x7fc00001)
        let ref = try #require(row["evidence"] as? [String:Any])
        let evidenceName = try #require(ref["file"] as? String)
        let json = try (Data(contentsOf:folder.appendingPathComponent(evidenceName)) as NSData).decompressed(using:.zlib) as Data
        let evidence = try #require(JSONSerialization.jsonObject(with:json) as? [String:Any])
        let model = try #require(evidence["model"] as? [String:Any])
        #expect(model["calibration"] == nil)
        #expect(model["units"] as? String == "relative_inverse_depth_not_meters")
    }
    @Test func videoAndLosslessEvidenceStayPairedAndRateLimited() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let recorder = DevCaptureRecorder(root:root); recorder.enable()
        recorder.submit(try packet(1,10)); try await waitIdle(recorder)
        recorder.submit(try packet(2,10.05)); try await waitIdle(recorder)
        recorder.submit(try packet(3,10.4)); try await waitIdle(recorder)
        #expect(recorder.status().saved == 2)
        await stop(recorder)
        #expect(!recorder.status().enabled)
        let folders = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
        let folder = try #require(folders.first)
        let manifest = try #require(JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("manifest.json"))) as? [String:Any])
        #expect(manifest["source"] as? String == "synthetic_test")
        let lines = try String(contentsOf:folder.appendingPathComponent("samples.jsonl"),encoding:.utf8).split(separator:"\n")
        #expect(lines.count == 2)
        let row = try #require(JSONSerialization.jsonObject(with:Data(lines[0].utf8)) as? [String:Any])
        let depth = try #require(row["depth"] as? [String:Any])
        let file = try #require(depth["file"] as? String)
        let raw = try (Data(contentsOf:folder.appendingPathComponent(file)) as NSData).decompressed(using:.zlib) as Data
        let n = Int(raw.withUnsafeBytes { $0.loadUnaligned(as:UInt32.self).littleEndian })
        let values = (0..<4).map { i in Float(bitPattern:raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:4+n+i*4,as:UInt32.self).littleEndian }) }
        #expect(values[0] == 1 && values[1].isNaN && values[2].isInfinite && values[3] == 2)
        let asset = AVURLAsset(url:folder.appendingPathComponent("camera.mp4"))
        let tracks = try await asset.loadTracks(withMediaType:.video)
        #expect(tracks.count == 1)
        #expect(try await asset.loadTracks(withMediaType:.audio).isEmpty)
        let reader = try AVAssetReader(asset:asset)
        let output = AVAssetReaderTrackOutput(track:try #require(tracks.first),outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(output); #expect(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() { times.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))) }
        #expect(reader.status == .completed)
        #expect(times.count == 2)
        #expect(abs((times.last ?? -1)-0.4) < 0.0001)
        // Re-enable creates a separate clip and resets the source time origin.
        recorder.enable(); recorder.submit(try packet(4,11)); try await waitIdle(recorder); await stop(recorder)
        #expect(try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).count == 2)
    }
}
#endif
