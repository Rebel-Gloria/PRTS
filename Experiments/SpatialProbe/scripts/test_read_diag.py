import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib
from read_diag import attachment, depth_frame, mesh_frame, records, summarize, extract, relative_frame, extract_prediction

class DiagnosticReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
    def binary(self, raw):
        compressor = zlib.compressobj(wbits=-15)
        compressed = compressor.compress(raw) + compressor.flush()
        (self.root / "data-00000.bin").write_bytes(struct.pack("<II", len(compressed), len(raw)) + compressed)
        return dict(file="data-00000.bin", codec="deflate-raw", offset=0, compressedBytes=len(compressed), uncompressedBytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())
    def depth(self):
        header = dict(kind="depth_frame", schemaVersion=1, source="synthetic", epoch=2, frameID=3, width=2, height=1, depthBytes=8, confidenceBytes=2)
        encoded = json.dumps(header).encode()
        return struct.pack("<I", len(encoded)) + encoded + struct.pack("<2f", 1.25, float("nan")) + bytes([2, 0])
    def prediction(self):
        h = dict(kind="relative_depth_frame", schemaVersion=1, units="relative_inverse_depth_not_meters", epoch=2, frameID=3,
                 width=2, height=1, depthBytes=8, modelRevision="synthetic-revision")
        encoded = json.dumps(h).encode()
        return h, struct.pack("<I", len(encoded)) + encoded + struct.pack("<2f", .8, .2)
    def test_path_and_haptics_summary_does_not_claim_safe_route(self):
        (self.root / "manifest.json").write_text(json.dumps({"source": "synthetic"}))
        payloads = [
            {"phase": "prediction", "update": {"reason": "new_blue_surface_path", "milliseconds": 1.2,
              "path": {"points": [[0, 0, -1], [0, 0, -2]]}}},
            {"phase": "feedback", "status": "submitted_aligned_once", "heading": {"angleDegrees": 2},
             "pulse": {"kind": "aligned_once", "intensity": 1}}
        ]
        (self.root / "path.jsonl").write_text("\n".join(json.dumps({"payload": p}) for p in payloads)+"\n")
        (self.root / "render.jsonl").write_text(json.dumps({"payload": {"phase": "submitted", "pathVertices": 6, "pathHistorical": True}})+"\n")
        out = summarize(self.root)
        self.assertEqual(out["pathAvailableAnalysisFrames"], 1)
        self.assertEqual(out["historicalPathRenderSubmissions"], 1)
        self.assertEqual(out["pathReasons"], {"new_blue_surface_path": 1})
        self.assertEqual(out["hapticRequestedPulseKinds"], {"aligned_once": 1})
        self.assertIn("not proof", out["note"])

    def test_fan_path_metrics_separate_observed_length_from_unknown_approach(self):
        (self.root / "manifest.json").write_text(json.dumps({"source": "synthetic"}))
        update = {"reason": "new_forward_fan_path", "targetGroundDistance": 3, "approachDistance": 1,
                  "reachableCells": 20, "path": {"points": [[0, 0, -1], [0, 0, -3]]}}
        (self.root / "path.jsonl").write_text(json.dumps({"payload": {"phase": "prediction", "update": update}})+"\n")
        (self.root / "render.jsonl").write_text(json.dumps({"payload": {"phase": "submitted", "pathVertices": 180,
                                                   "pathApproachVertices": 30, "pathTargetVertices": 144}})+"\n")
        out = summarize(self.root)
        self.assertEqual(out["pathTargetDistanceMeters"]["p50"], 3)
        self.assertEqual(out["pathUnknownApproachMeters"]["p50"], 1)
        self.assertEqual(out["pathLengthMeters"]["p50"], 2)
        self.assertEqual(out["pathTargetRenderSubmissions"], 1)
        self.assertEqual(out["pathApproachRenderSubmissions"], 1)

    def test_fixed_goal_metadata_is_not_counted_as_renderable_path(self):
        (self.root / "manifest.json").write_text(json.dumps({"source": "synthetic"}))
        rows = [
            {"phase": "prediction", "update": {"goal": {"epoch": 1, "id": 10}, "goalChangeReason": "selected_farthest"}},
            {"phase": "prediction", "update": {"goal": {"epoch": 1, "id": 10}, "reason": "fixed_goal_waiting_evidence"}},
            {"phase": "feedback", "status": "submitted_left_double", "pulse": {"kind": "left_double", "segments": [{}, {}]}},
            {"phase": "feedback", "status": "submitted_right_long", "pulse": {"kind": "right_long", "segments": [{}]}}
        ]
        (self.root / "path.jsonl").write_text("\n".join(json.dumps({"payload": p}) for p in rows)+"\n")
        out = summarize(self.root)
        self.assertEqual(out["distinctFixedGoals"], 1)
        self.assertEqual(out["fixedGoalWithoutPathFrames"], 2)
        self.assertEqual(out["pathAvailableAnalysisFrames"], 0)
        self.assertEqual(out["fixedGoalChanges"], {"selected_farthest": 1})
        self.assertEqual(out["hapticRequestedPulseKinds"], {"left_double": 1, "right_long": 1})

    def test_relative_prediction_keeps_units_and_cannot_decode_as_measured_depth(self):
        h, raw = self.prediction()
        actual, data = relative_frame(raw)
        self.assertEqual(actual, h)
        self.assertAlmostEqual(struct.unpack_from("<f", data)[0], .8)
        with self.assertRaises(ValueError): depth_frame(raw)
        with self.assertRaises(ValueError): relative_frame(self.depth())
    def test_relative_prediction_rejects_bad_size_and_wrong_units(self):
        h, raw = self.prediction()
        with self.assertRaises(ValueError): relative_frame(raw[:-1])
        h["units"] = "meters"
        encoded = json.dumps(h).encode()
        with self.assertRaises(ValueError): relative_frame(struct.pack("<I", len(encoded))+encoded+bytes(8))
    def test_prediction_support_never_becomes_confidence(self):
        h = dict(kind="depth_frame", schemaVersion=1, width=2, height=1, depthBytes=8, confidenceBytes=0,
                 predictionSupportBytes=2, depthEvidence="model_prediction_arkit_aligned_not_sensor_confidence")
        encoded = json.dumps(h).encode()
        raw = struct.pack("<I", len(encoded))+encoded+struct.pack("<2f",1,2)+bytes([1,0])
        metadata, data, confidence = depth_frame(raw)
        self.assertEqual(confidence, b"")
        self.assertEqual(metadata["predictionSupportBytes"], 2)
        with self.assertRaises(ValueError): depth_frame(raw[:-1])
    def test_prediction_stream_verified_and_extractable_without_rgb(self):
        h, raw = self.prediction()
        row = dict(payload=h, attachment=self.binary(raw), sequence=1)
        (self.root / "manifest.json").write_text(json.dumps(dict(source="synthetic")))
        (self.root / "prediction.jsonl").write_text(json.dumps(row)+"\n")
        summary = summarize(self.root, verify=True)
        self.assertEqual(summary["counts"]["prediction"], 1)
        self.assertEqual(summary["attachmentVerified"], 1)
        self.assertEqual(summary["attachmentErrors"], [])
        target = extract_prediction(self.root, "2:3", self.root / "extract")
        self.assertTrue((target / "relative-inverse-depth.f32le").exists())
        self.assertFalse((target / "depth.f32le").exists())
        self.assertFalse((target / "confidence.u8").exists())
    def test_prediction_identity_mismatch_reported(self):
        h, raw = self.prediction()
        h["frameID"] = 4
        (self.root / "manifest.json").write_text(json.dumps(dict(source="synthetic")))
        (self.root / "prediction.jsonl").write_text(json.dumps(dict(payload=h,attachment=self.binary(raw)))+"\n")
        self.assertEqual(len(summarize(self.root, verify=True)["attachmentErrors"]), 1)
    def test_portable_binary_roundtrip(self):
        raw = self.depth()
        header, depth, confidence = depth_frame(attachment(self.root, self.binary(raw)))
        self.assertEqual(header["source"], "synthetic")
        self.assertEqual(struct.unpack_from("<f", depth)[0], 1.25)
        self.assertEqual(confidence, bytes([2, 0]))
    def test_checksum_detects_corruption(self):
        ref = self.binary(self.depth()); ref["sha256"] = "wrong"
        with self.assertRaises(ValueError): attachment(self.root, ref)
    def test_truncated_attachment_is_not_silently_accepted(self):
        ref = self.binary(self.depth())
        path = self.root / ref["file"]; path.write_bytes(path.read_bytes()[:-3])
        with self.assertRaises(ValueError): attachment(self.root, ref)
    def test_path_traversal_is_rejected(self):
        ref = self.binary(self.depth()); ref["file"] = "../outside"
        with self.assertRaises(ValueError): attachment(self.root, ref)
    def test_interrupted_json_tail_is_reported_and_earlier_data_survives(self):
        path = self.root / "events.jsonl"
        path.write_bytes(b'{"payload":{"name":"launch"}}\n{"payload":')
        issues = []; values = list(records(path, issues))
        self.assertEqual(len(values), 1); self.assertEqual(len(issues), 1)
    def test_summary_and_extract_have_no_images(self):
        ref = self.binary(self.depth())
        (self.root / "manifest.json").write_text(json.dumps(dict(source="synthetic", runID="test")))
        row = dict(payload=dict(frame=dict(epoch=2, frameID=3, sourceDirectionStable=False, surfaceModel={}), diagnostics=dict(modelState="built", modelBlockReasons=[]), depthAttachmentExpected=True), attachment=ref)
        (self.root / "analysis.jsonl").write_text(json.dumps(row) + "\n")
        summary = summarize(self.root, True)
        self.assertEqual(summary["attachmentVerified"], 1)
        self.assertEqual(summary["unstableDirectionModelFrames"], 1)
        self.assertEqual(summary["unexpectedImageFiles"], [])
        target = extract(self.root, "2:3", self.root / "extract")
        self.assertEqual((target / "depth.f32le").stat().st_size, 8)
        self.assertFalse((target / "rgb.jpg").exists())
        with self.assertRaises(FileExistsError): extract(self.root, "2:3", self.root / "extract")
    def test_scale_decisions_and_reference_modes_are_counted_without_manual_duplicates(self):
        (self.root / "manifest.json").write_text(json.dumps(dict(source="synthetic", runID="test")))
        record = dict(calibration={"synthetic": True}, provisionalFit={"synthetic": True},
                      scaleDecision=dict(reason="world_reprojection_confirmed", medianRelativeError=0.01, inliers=32),
                      groundReference=dict(mode="retained_reference"))
        rows = [dict(payload=record), dict(payload={**record, "manual": True}), dict(payload=dict(scaleDecision=dict(reason="current_metric_fit_unavailable")))]
        (self.root / "prediction.jsonl").write_text("".join(json.dumps(r)+"\n" for r in rows))
        summary = summarize(self.root)
        self.assertEqual(summary["predictionConfirmedFrames"], 1)
        self.assertEqual(summary["predictionProvisionalFits"], 1)
        self.assertEqual(summary["predictionScaleReasons"], {"world_reprojection_confirmed": 1, "current_metric_fit_unavailable": 1})
        self.assertEqual(summary["predictionGroundModes"]["retained_reference"], 1)
    def test_legacy_prediction_does_not_invent_temporal_evidence(self):
        (self.root / "manifest.json").write_text(json.dumps(dict(source="synthetic", runID="test")))
        (self.root / "prediction.jsonl").write_text(json.dumps(dict(payload=dict(calibration={"legacy": True})))+"\n")
        summary = summarize(self.root)
        self.assertEqual(summary["predictionScaleReasons"], {"legacy_unavailable": 1})
        self.assertEqual(summary["predictionProvisionalFits"], 0)
        self.assertEqual(summary["predictionConfirmedFrames"], 1)
    def test_reference_and_history_are_not_reported_as_current_geometry(self):
        (self.root / "manifest.json").write_text(json.dumps(dict(source="synthetic", runID="test")))
        (self.root / "analysis.jsonl").write_text(json.dumps(dict(payload=dict(frame={}, diagnostics=dict(groundReferenceMode="retained_world_reference")))) + "\n")
        (self.root / "render.jsonl").write_text(json.dumps(dict(payload=dict(phase="submitted", geometryBlockReason="analysis_expired", surfacePresentationMode="historical_wireframe"))) + "\n")
        summary = summarize(self.root)
        self.assertEqual(summary["groundReferenceModes"], {"retained_world_reference": 1})
        self.assertEqual(summary["surfacePresentationModes"], {"historical_wireframe": 1})
        self.assertEqual(summary["geometryGateReasons"], {"analysis_expired": 1})
    def mesh(self):
        h = dict(kind="mesh_frame", schemaVersion=1, source="synthetic", id="mesh", epoch=1, revision=2,
                 vertexCount=3, indexCount=3, classificationCount=1)
        header = json.dumps(h).encode()
        return struct.pack("<I", len(header)) + header + struct.pack("<9f3IB", 0,0,0, 1,0,0, 0,0,1, 0,1,2, 2)
    def test_binary_mesh_roundtrip_and_summary(self):
        raw = self.mesh(); h, vertices, indices, classes = mesh_frame(raw)
        self.assertEqual((len(vertices), len(indices), classes), (36,12,bytes([2])))
        self.assertEqual(h["source"], "synthetic")
        (self.root / "manifest.json").write_text(json.dumps(dict(source="synthetic", runID="mesh-test")))
        row = dict(payload=dict(id="mesh", epoch=1, revision=2, attachmentKind="mesh_frame_binary_v1"), attachment=self.binary(raw))
        (self.root / "mesh.jsonl").write_text(json.dumps(row) + "\n")
        result = summarize(self.root, True)
        self.assertEqual(result["attachmentVerified"], 1); self.assertEqual(result["attachmentErrors"], [])
    def test_legacy_json_mesh_remains_readable(self):
        raw = json.dumps(dict(id="mesh", epoch=1, revision=2, vertices=[], indices=[], classifications=[])).encode()
        (self.root / "manifest.json").write_text(json.dumps(dict(source="synthetic", runID="mesh-test")))
        row = dict(payload=dict(id="mesh", epoch=1, revision=2, attachmentKind="mesh_snapshot_json"), attachment=self.binary(raw))
        (self.root / "mesh.jsonl").write_text(json.dumps(row) + "\n")
        self.assertEqual(summarize(self.root, True)["attachmentErrors"], [])
    def test_binary_mesh_rejects_truncation_and_corrupt_indices(self):
        with self.assertRaises(ValueError): mesh_frame(self.mesh()[:-1])
        b = bytearray(self.mesh()); n = struct.unpack_from("<I", b)[0]
        struct.pack_into("<I", b, 4+n+36, 99)
        with self.assertRaises(ValueError): mesh_frame(b)
    def test_binary_mesh_rejects_nonfinite_geometry(self):
        b = bytearray(self.mesh()); n = struct.unpack_from("<I", b)[0]
        struct.pack_into("<f", b, 4+n, float("nan"))
        with self.assertRaises(ValueError): mesh_frame(b)
    def test_no_confidence_is_distinct_from_zero_confidence(self):
        raw = self.depth(); n = struct.unpack_from("<I", raw)[0]
        header = json.loads(raw[4:4+n]); header["confidenceBytes"] = 0
        encoded = json.dumps(header).encode()
        header, _, confidence = depth_frame(struct.pack("<I", len(encoded)) + encoded + raw[4+n:4+n+8])
        self.assertEqual(confidence, b"")
    def test_mismatched_dimensions_are_rejected(self):
        raw = self.depth(); n = struct.unpack_from("<I", raw)[0]
        header = json.loads(raw[4:4+n]); header["width"] = 100
        encoded = json.dumps(header).encode()
        with self.assertRaises(ValueError): depth_frame(struct.pack("<I", len(encoded)) + encoded + raw[4+n:])

if __name__ == "__main__": unittest.main()
