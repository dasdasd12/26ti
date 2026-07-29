#!/usr/bin/env python
"""Unit tests for the non-RTL frequency-offset simulation."""

from __future__ import print_function

import math
import unittest
from dataclasses import replace

import numpy as np

from frequency_offset_sim import (
    SimulationConfig,
    dds_frequency,
    estimate_frequency_offset,
    run_calibration,
    simulate_camera_phase,
)


class FrequencyOffsetSimulationTests(unittest.TestCase):
    def setUp(self):
        self.config = SimulationConfig(
            phase_noise_deg=0.5,
            outlier_probability=0.02,
            seed=12345,
        )

    def test_32_bit_dds_quantization_is_below_target(self):
        dds_lsb_hz = (
            self.config.nominal_sample_rate_hz
            / float(1 << self.config.dds_accumulator_bits)
        )
        self.assertLess(dds_lsb_hz / 2.0, 0.01)

        physical_hz, _ = dds_frequency(100_000.0, self.config)
        self.assertGreater(physical_hz, 100_000.0)

    def test_wrapped_phase_estimator_tracks_known_offset(self):
        random_state = np.random.RandomState(7)
        times_s, phase_rad = simulate_camera_phase(
            offset_hz=4.75,
            duration_s=3.0,
            config=self.config,
            random_state=random_state,
            initial_phase_rad=0.37,
        )
        estimate_hz = estimate_frequency_offset(times_s, phase_rad)
        self.assertLess(abs(estimate_hz - 4.75), 0.01)

    def test_worst_case_100khz_positive_50ppm(self):
        result = run_calibration(
            self.config,
            random_state=np.random.RandomState(11),
        )
        self.assertGreater(
            abs(result.true_offset_before_hz),
            4.9,
        )
        self.assertLess(
            abs(result.true_offset_after_hz),
            self.config.target_offset_hz,
        )
        self.assertLess(
            abs(result.estimated_offset_after_hz),
            self.config.target_offset_hz,
        )
        self.assertTrue(result.passed)

    def test_representative_band_and_harmonic_cases(self):
        random_state = np.random.RandomState(19)
        for harmonic in (1, 2):
            for clock_error_ppm in (-50.0, 50.0):
                for source_frequency_hz in (
                    1_000.0,
                    10_000.0,
                    50_000.0,
                    100_000.0,
                ):
                    config = replace(
                        self.config,
                        harmonic=harmonic,
                        clock_error_ppm=clock_error_ppm,
                        source_frequency_hz=source_frequency_hz,
                    )
                    result = run_calibration(
                        config,
                        random_state=random_state,
                    )
                    self.assertTrue(
                        result.passed,
                        msg=(
                            "failed at harmonic=%d, frequency=%.1f, "
                            "clock=%+.1f ppm, residual=%+.6f Hz"
                            % (
                                harmonic,
                                source_frequency_hz,
                                clock_error_ppm,
                                result.true_offset_after_hz,
                            )
                        ),
                    )


if __name__ == "__main__":
    unittest.main(verbosity=2)
