#!/usr/bin/env python
"""Direct source-to-FPGA clock-ratio calibration, without a camera.

Before the electrical connection is removed, a known signal-source setting is
sampled for a fixed interval.  Counting local sample ticks over an integer
number of source periods estimates the FPGA clock relative to the source
timebase.  Later DDS words use that measured ratio directly.
"""

from __future__ import print_function

import argparse
import csv
import json
import math
import os
from dataclasses import dataclass, replace

import numpy as np


@dataclass
class DirectCalibrationConfig:
    calibration_frequency_hz: float = 100_000.0
    calibration_time_s: float = 5.0
    nominal_sample_rate_hz: float = 12_500_000.0
    dds_accumulator_bits: int = 32
    source_clock_error_ppm: float = 0.0
    fpga_clock_error_ppm: float = 50.0
    endpoint_error_ticks: int = 0
    target_offset_hz: float = 0.01


@dataclass
class ClockCalibration:
    source_cycles: int
    measured_sample_ticks: int
    effective_sample_rate_hz: float
    true_effective_sample_rate_hz: float
    estimated_relative_scale: float
    true_relative_scale: float
    scale_error_ppm: float
    correction_coefficient: float


@dataclass
class FrequencyResult:
    source_frequency_hz: float
    harmonic: int
    source_clock_error_ppm: float
    fpga_clock_error_ppm: float
    endpoint_error_ticks: int
    desired_physical_frequency_hz: float
    uncalibrated_output_frequency_hz: float
    calibrated_output_frequency_hz: float
    uncalibrated_offset_hz: float
    calibrated_offset_hz: float
    calibrated_tuning_word: int
    passed: bool

    def csv_row(self):
        return {
            "source_frequency_hz": self.source_frequency_hz,
            "harmonic": self.harmonic,
            "source_clock_error_ppm": self.source_clock_error_ppm,
            "fpga_clock_error_ppm": self.fpga_clock_error_ppm,
            "endpoint_error_ticks": self.endpoint_error_ticks,
            "desired_physical_frequency_hz":
                self.desired_physical_frequency_hz,
            "uncalibrated_output_frequency_hz":
                self.uncalibrated_output_frequency_hz,
            "calibrated_output_frequency_hz":
                self.calibrated_output_frequency_hz,
            "uncalibrated_offset_hz": self.uncalibrated_offset_hz,
            "calibrated_offset_hz": self.calibrated_offset_hz,
            "calibrated_tuning_word": self.calibrated_tuning_word,
            "passed": self.passed,
        }


def source_scale(config):
    return 1.0 + config.source_clock_error_ppm * 1.0e-6


def fpga_scale(config):
    return 1.0 + config.fpga_clock_error_ppm * 1.0e-6


def actual_sample_rate_hz(config):
    return config.nominal_sample_rate_hz * fpga_scale(config)


def calibrate_clock_ratio(config):
    """Estimate the FPGA sample clock in source-timebase units.

    An integer number of source cycles defines the observation interval.
    Source absolute error cancels because the same source timebase is used
    during calibration and later generation targets.
    """
    source_cycles = int(round(
        config.calibration_frequency_hz * config.calibration_time_s
    ))
    if source_cycles < 1:
        raise ValueError("Calibration interval contains no source cycles")

    physical_calibration_frequency_hz = (
        config.calibration_frequency_hz * source_scale(config)
    )
    true_interval_s = (
        source_cycles / physical_calibration_frequency_hz
    )
    true_sample_ticks = actual_sample_rate_hz(config) * true_interval_s

    # The +/-1 tick option models uncertainty at the two detected endpoints.
    measured_sample_ticks = (
        int(round(true_sample_ticks)) + config.endpoint_error_ticks
    )
    if measured_sample_ticks <= 0:
        raise ValueError("Measured sample-tick count must be positive")

    # Express the local sample rate in the signal source's nominal timebase.
    effective_sample_rate_hz = (
        measured_sample_ticks
        * config.calibration_frequency_hz
        / source_cycles
    )
    true_effective_sample_rate_hz = (
        actual_sample_rate_hz(config) / source_scale(config)
    )
    estimated_relative_scale = (
        effective_sample_rate_hz / config.nominal_sample_rate_hz
    )
    true_relative_scale = (
        true_effective_sample_rate_hz
        / config.nominal_sample_rate_hz
    )
    scale_error_ppm = (
        estimated_relative_scale / true_relative_scale - 1.0
    ) * 1.0e6

    return ClockCalibration(
        source_cycles=source_cycles,
        measured_sample_ticks=measured_sample_ticks,
        effective_sample_rate_hz=effective_sample_rate_hz,
        true_effective_sample_rate_hz=true_effective_sample_rate_hz,
        estimated_relative_scale=estimated_relative_scale,
        true_relative_scale=true_relative_scale,
        scale_error_ppm=scale_error_ppm,
        correction_coefficient=(
            config.nominal_sample_rate_hz
            / effective_sample_rate_hz
        ),
    )


def _dds_output_frequency_hz(tuning_word, config):
    modulus = 1 << config.dds_accumulator_bits
    return (
        tuning_word
        * actual_sample_rate_hz(config)
        / modulus
    )


def evaluate_frequency(
    source_frequency_hz,
    harmonic,
    config,
    calibration,
):
    if harmonic not in (1, 2):
        raise ValueError("harmonic must be 1 or 2")
    if not 1_000.0 <= source_frequency_hz <= 100_000.0:
        raise ValueError("source frequency must be within 1-100 kHz")

    target_nominal_hz = harmonic * source_frequency_hz
    desired_physical_hz = target_nominal_hz * source_scale(config)
    modulus = 1 << config.dds_accumulator_bits

    uncalibrated_word = int(round(
        target_nominal_hz
        * modulus
        / config.nominal_sample_rate_hz
    ))
    calibrated_word = int(round(
        target_nominal_hz
        * modulus
        / calibration.effective_sample_rate_hz
    ))

    uncalibrated_output_hz = _dds_output_frequency_hz(
        uncalibrated_word, config
    )
    calibrated_output_hz = _dds_output_frequency_hz(
        calibrated_word, config
    )
    uncalibrated_offset_hz = (
        uncalibrated_output_hz - desired_physical_hz
    )
    calibrated_offset_hz = calibrated_output_hz - desired_physical_hz

    return FrequencyResult(
        source_frequency_hz=source_frequency_hz,
        harmonic=harmonic,
        source_clock_error_ppm=config.source_clock_error_ppm,
        fpga_clock_error_ppm=config.fpga_clock_error_ppm,
        endpoint_error_ticks=config.endpoint_error_ticks,
        desired_physical_frequency_hz=desired_physical_hz,
        uncalibrated_output_frequency_hz=uncalibrated_output_hz,
        calibrated_output_frequency_hz=calibrated_output_hz,
        uncalibrated_offset_hz=uncalibrated_offset_hz,
        calibrated_offset_hz=calibrated_offset_hz,
        calibrated_tuning_word=calibrated_word,
        passed=abs(calibrated_offset_hz) < config.target_offset_hz,
    )


def run_full_sweep(base_config):
    results = []
    frequencies_hz = np.arange(1_000.0, 100_000.0 + 50.0, 100.0)
    relative_clock_errors_ppm = (-50.0, -25.0, 25.0, 50.0)
    endpoint_errors_ticks = (-1, 0, 1)

    for relative_error_ppm in relative_clock_errors_ppm:
        for endpoint_error_ticks in endpoint_errors_ticks:
            # Keep the source timebase error in the model.  Adjust the FPGA
            # error so the requested relative difference is exercised.
            fpga_error_ppm = (
                base_config.source_clock_error_ppm
                + relative_error_ppm
            )
            config = replace(
                base_config,
                fpga_clock_error_ppm=fpga_error_ppm,
                endpoint_error_ticks=endpoint_error_ticks,
            )
            calibration = calibrate_clock_ratio(config)
            for harmonic in (1, 2):
                for frequency_hz in frequencies_hz:
                    results.append(
                        evaluate_frequency(
                            float(frequency_hz),
                            harmonic,
                            config,
                            calibration,
                        )
                    )

    return results


def write_sweep_csv(results, output_path):
    fieldnames = list(results[0].csv_row().keys())
    with open(output_path, "w", newline="", encoding="utf-8") as output_file:
        writer = csv.DictWriter(output_file, fieldnames=fieldnames)
        writer.writeheader()
        for result in results:
            writer.writerow(result.csv_row())


def make_sweep_plot(results, target_offset_hz, output_path):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    figure, axes = plt.subplots(1, 2, figsize=(12, 4.8), sharey=True)
    for axis, harmonic in zip(axes, (1, 2)):
        harmonic_results = [
            result for result in results
            if result.harmonic == harmonic
        ]
        frequencies_hz = sorted(set(
            result.source_frequency_hz for result in harmonic_results
        ))
        uncalibrated_envelope = []
        calibrated_envelope = []
        for frequency_hz in frequencies_hz:
            at_frequency = [
                result for result in harmonic_results
                if result.source_frequency_hz == frequency_hz
            ]
            uncalibrated_envelope.append(max(
                abs(result.uncalibrated_offset_hz)
                for result in at_frequency
            ))
            calibrated_envelope.append(max(
                abs(result.calibrated_offset_hz)
                for result in at_frequency
            ))

        axis.semilogy(
            frequencies_hz,
            uncalibrated_envelope,
            label="without calibration",
        )
        axis.semilogy(
            frequencies_hz,
            calibrated_envelope,
            label="direct clock-ratio calibration",
        )
        axis.axhline(
            target_offset_hz,
            color="tab:red",
            linestyle="--",
            label="0.01 Hz target",
        )
        axis.set_title("%dx output" % harmonic)
        axis.set_xlabel("Signal-source setting (Hz)")
        axis.grid(True, which="both", alpha=0.3)
        axis.legend(loc="best")

    axes[0].set_ylabel("Absolute offset relative to source (Hz)")
    figure.suptitle(
        "5 s direct calibration, full 1-100 kHz sweep"
    )
    figure.tight_layout(rect=(0.0, 0.0, 1.0, 0.94))
    figure.savefig(output_path, dpi=160)
    plt.close(figure)


def write_summary_json(
    config,
    calibration,
    demo_result,
    sweep_results,
    output_path,
):
    summary = {
        "method": (
            "count local 12.5 MHz sample ticks over an integer number "
            "of electrically connected source periods"
        ),
        "calibration": {
            "calibration_frequency_hz":
                config.calibration_frequency_hz,
            "calibration_time_s": config.calibration_time_s,
            "source_cycles": calibration.source_cycles,
            "measured_sample_ticks":
                calibration.measured_sample_ticks,
            "estimated_relative_scale":
                calibration.estimated_relative_scale,
            "true_relative_scale":
                calibration.true_relative_scale,
            "scale_error_ppm": calibration.scale_error_ppm,
            "correction_coefficient":
                calibration.correction_coefficient,
        },
        "demo": demo_result.csv_row(),
        "sweep": {
            "frequency_start_hz": 1_000.0,
            "frequency_stop_hz": 100_000.0,
            "frequency_step_hz": 100.0,
            "harmonics": [1, 2],
            "relative_clock_errors_ppm":
                [-50.0, -25.0, 25.0, 50.0],
            "endpoint_errors_ticks": [-1, 0, 1],
            "case_count": len(sweep_results),
            "failed_case_count": sum(
                not result.passed for result in sweep_results
            ),
            "max_uncalibrated_offset_hz": max(
                abs(result.uncalibrated_offset_hz)
                for result in sweep_results
            ),
            "max_calibrated_offset_hz": max(
                abs(result.calibrated_offset_hz)
                for result in sweep_results
            ),
            "target_offset_hz": config.target_offset_hz,
        },
    }
    with open(output_path, "w", encoding="utf-8") as output_file:
        json.dump(summary, output_file, indent=2, ensure_ascii=False)
        output_file.write("\n")


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Directly calibrate the FPGA clock against an electrically "
            "connected signal-source reference."
        )
    )
    parser.add_argument(
        "--calibration-frequency-hz",
        type=float,
        default=100_000.0,
    )
    parser.add_argument(
        "--calibration-time-s",
        type=float,
        default=5.0,
    )
    parser.add_argument(
        "--source-clock-error-ppm",
        type=float,
        default=0.0,
    )
    parser.add_argument(
        "--fpga-clock-error-ppm",
        type=float,
        default=50.0,
    )
    parser.add_argument(
        "--endpoint-error-ticks",
        type=int,
        default=0,
        choices=(-1, 0, 1),
    )
    parser.add_argument(
        "--output-dir",
        default=None,
    )
    parser.add_argument(
        "--no-plots",
        action="store_true",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    script_directory = os.path.dirname(os.path.abspath(__file__))
    output_directory = (
        os.path.abspath(args.output_dir)
        if args.output_dir
        else os.path.join(script_directory, "direct_output")
    )
    if not os.path.isdir(output_directory):
        os.makedirs(output_directory)

    config = DirectCalibrationConfig(
        calibration_frequency_hz=args.calibration_frequency_hz,
        calibration_time_s=args.calibration_time_s,
        source_clock_error_ppm=args.source_clock_error_ppm,
        fpga_clock_error_ppm=args.fpga_clock_error_ppm,
        endpoint_error_ticks=args.endpoint_error_ticks,
    )
    calibration = calibrate_clock_ratio(config)
    demo_result = evaluate_frequency(
        source_frequency_hz=100_000.0,
        harmonic=2,
        config=config,
        calibration=calibration,
    )
    sweep_results = run_full_sweep(config)

    write_sweep_csv(
        sweep_results,
        os.path.join(output_directory, "frequency_sweep.csv"),
    )
    write_summary_json(
        config,
        calibration,
        demo_result,
        sweep_results,
        os.path.join(output_directory, "summary.json"),
    )
    if not args.no_plots:
        make_sweep_plot(
            sweep_results,
            config.target_offset_hz,
            os.path.join(
                output_directory,
                "direct_calibration_sweep.png",
            ),
        )

    failed_cases = [
        result for result in sweep_results if not result.passed
    ]
    max_residual_hz = max(
        abs(result.calibrated_offset_hz)
        for result in sweep_results
    )
    print(
        "[CAL] source cycles=%d, local sample ticks=%d"
        % (
            calibration.source_cycles,
            calibration.measured_sample_ticks,
        )
    )
    print(
        "[CAL] relative scale=%.12f, scale error=%+.6f ppm"
        % (
            calibration.estimated_relative_scale,
            calibration.scale_error_ppm,
        )
    )
    print(
        "[DEMO] 2x 100 kHz: before=%+.6f Hz, after=%+.6f Hz"
        % (
            demo_result.uncalibrated_offset_hz,
            demo_result.calibrated_offset_hz,
        )
    )
    print(
        "[SWEEP] %d cases, %d failures, max residual=%.6f Hz"
        % (
            len(sweep_results),
            len(failed_cases),
            max_residual_hz,
        )
    )
    print("[OUTPUT] %s" % output_directory)

    return 0 if not failed_cases else 1


if __name__ == "__main__":
    raise SystemExit(main())
