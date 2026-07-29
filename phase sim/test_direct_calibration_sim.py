#!/usr/bin/env python
"""Tests for direct electrical clock-ratio calibration."""

from __future__ import print_function

import unittest
from dataclasses import replace

from direct_calibration_sim import (
    DirectCalibrationConfig,
    calibrate_clock_ratio,
    evaluate_frequency,
)


class DirectCalibrationTests(unittest.TestCase):
    def setUp(self):
        self.config = DirectCalibrationConfig()

    def test_measured_scale_tracks_relative_clock_error(self):
        calibration = calibrate_clock_ratio(self.config)
        expected_scale = (
            (1.0 + self.config.fpga_clock_error_ppm * 1.0e-6)
            / (1.0 + self.config.source_clock_error_ppm * 1.0e-6)
        )
        self.assertLess(
            abs(calibration.estimated_relative_scale - expected_scale),
            2.0e-8,
        )

    def test_source_absolute_error_cancels(self):
        config = replace(
            self.config,
            source_clock_error_ppm=12.0,
            fpga_clock_error_ppm=-38.0,
        )
        calibration = calibrate_clock_ratio(config)
        result = evaluate_frequency(
            100_000.0,
            2,
            config,
            calibration,
        )
        self.assertLess(
            abs(result.calibrated_offset_hz),
            config.target_offset_hz,
        )

    def test_worst_endpoint_quantization_stays_below_target(self):
        for relative_error_ppm in (-50.0, 50.0):
            for endpoint_error_ticks in (-1, 1):
                config = replace(
                    self.config,
                    fpga_clock_error_ppm=relative_error_ppm,
                    endpoint_error_ticks=endpoint_error_ticks,
                )
                calibration = calibrate_clock_ratio(config)
                result = evaluate_frequency(
                    100_000.0,
                    2,
                    config,
                    calibration,
                )
                self.assertTrue(
                    result.passed,
                    msg=(
                        "ppm=%+.1f, endpoint=%+d, residual=%+.6f Hz"
                        % (
                            relative_error_ppm,
                            endpoint_error_ticks,
                            result.calibrated_offset_hz,
                        )
                    ),
                )

    def test_representative_full_band_points(self):
        for harmonic in (1, 2):
            for frequency_hz in (
                1_000.0,
                10_000.0,
                50_000.0,
                100_000.0,
            ):
                calibration = calibrate_clock_ratio(self.config)
                result = evaluate_frequency(
                    frequency_hz,
                    harmonic,
                    self.config,
                    calibration,
                )
                self.assertTrue(result.passed)


if __name__ == "__main__":
    unittest.main(verbosity=2)
