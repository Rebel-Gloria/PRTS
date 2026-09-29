import unittest
from compare_route_replays import compare


class RouteReplayTests(unittest.TestCase):
    def row(self, frame=1):
        return {"epoch": 1, "frameID": frame, "timestamp": 1,
                "update": {"milliseconds": 1, "reason": "synthetic"}}

    def test_pairing_mismatch_is_rejected(self):
        with self.assertRaises(ValueError):
            compare([self.row()], [self.row(2)])

    def test_missing_invariants_are_not_counted_as_verified(self):
        result = compare([self.row()], [self.row()])["total"]["after"]
        self.assertEqual(result["invariantChecksPresent"], 0)
        self.assertIsNone(result["lengthMeters"]["p50"])

    def test_detects_recorded_collision_and_unsupported_path(self):
        row = self.row()
        row.update(fresh=True, supportedByCurrentGrid=False, currentObstacleFree=False)
        result = compare([row], [row])["total"]["after"]
        self.assertEqual(result["freshUnsupported"], 1)
        self.assertEqual(result["currentObstacleConflicts"], 1)


if __name__ == "__main__":
    unittest.main()
