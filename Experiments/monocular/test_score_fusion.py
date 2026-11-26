"""Metric assertions must not turn missing depths or calibration neighbors into successes."""

import unittest

import numpy as np
from score_fusion import HEIGHT, WIDTH, holdout, metric_stats


class FusionScoreTests(unittest.TestCase):
    def test_missing_estimates_count_against_coverage_not_error(self):
        measured = metric_stats(np.array([1.0, 2.0, 5.0]), np.array([1.5, 1.0, np.nan]))
        self.assertEqual(measured["valid_pixels"], 2)
        self.assertAlmostEqual(measured["coverage"], 2 / 3)
        self.assertAlmostEqual(measured["mae_m"], 0.75)
        self.assertAlmostEqual(measured["bias_m"], -0.25)
        self.assertEqual((measured["over_20pct_pixels"], measured["under_20pct_pixels"]), (1, 1))
        missing = metric_stats(np.array([1.0]), np.array([np.nan]))
        self.assertEqual(missing["coverage"], 0)
        self.assertIsNone(missing["mae_m"])

    def test_off_grid_calibration_and_surface_edge_are_excluded(self):
        z = np.ones((HEIGHT, WIDTH))
        labels = np.ones(z.shape, dtype=np.uint8)
        used = np.zeros(z.shape, dtype=np.uint8)
        used[9, 9] = 1  # Off-grid calibration, two pixels diagonally from (7, 7).
        labels[13, 18] = 2  # Different surface diagonally adjacent to (12, 17).
        (y, x), _ = holdout(z, labels, used)
        kept = set(zip(y, x, strict=True))
        self.assertNotIn((7, 7), kept)
        self.assertNotIn((12, 17), kept)
        self.assertIn((7, 12), kept)
