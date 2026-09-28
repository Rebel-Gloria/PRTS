import unittest
from summarize_session import stats, evaluate

class ReportTests(unittest.TestCase):
    def test_empty_not_zero(self):
        self.assertIsNone(stats([None, "", "nan"])["mean"])
    def test_percentiles(self):
        self.assertEqual(stats([0, 10])["p95"], 9.5)
    def test_false_candidate_is_failure_and_missing_is_not_zero_error(self):
        frame = dict(epoch=1, frameID=2, source="synthetic", metrics={"outputEligible": True}, distances=[], segments=[dict(sector="center", minimumObservedWidth=1.0)])
        label = dict(epoch="1", frameID="2", sector="center", gt_obstacle_ground_m="2", gt_channel_width_m="0.6", candidate_label="unsafe")
        report = evaluate([frame], [label])
        self.assertEqual(report["unsafeCandidateEvents"], 1)
        self.assertEqual(report["distanceUnavailable"], 1)
        self.assertIsNone(report["distanceAbsoluteErrorMeters"]["mean"])
        self.assertAlmostEqual(report["widthAbsoluteErrorMeters"]["mean"], .4)
        self.assertTrue(report["acceptance"].startswith("FAIL"))
    def test_ineligible_computation_not_counted_as_emitted_candidate(self):
        frame = dict(epoch=1, frameID=1, metrics={"outputEligible": False}, segments=[dict(sector="left", minimumObservedWidth=1.0)])
        label = dict(epoch="1", frameID="1", sector="left", candidate_label="unsafe")
        self.assertEqual(evaluate([frame], [label])["unsafeCandidateEvents"], 0)
    def test_visible_moving_geometry_is_not_emitted_navigation(self):
        frame = dict(epoch=1, frameID=1, source="synthetic",
                     metrics={"geometryOutputEligible": True, "outputEligible": False},
                     distances=[dict(sector="left", groundDistance=1.2)],
                     segments=[dict(sector="left", minimumObservedWidth=1.0)])
        label = dict(epoch="1", frameID="1", sector="left", candidate_label="unsafe",
                     gt_obstacle_ground_m="1.2", gt_channel_width_m="0.9")
        report = evaluate([frame], [label])
        self.assertEqual(report["unsafeCandidateEvents"], 0)
        self.assertEqual(report["distanceUnavailable"], 1)
        self.assertEqual(report["widthUnavailable"], 1)
    def test_duplicate_labels_rejected(self):
        label = dict(epoch="1", frameID="1", sector="left")
        with self.assertRaises(ValueError):
            evaluate([], [label, label])

if __name__ == "__main__":
    unittest.main()
