#!/usr/bin/env python
"""Camera-observed frequency-offset calibration for Lissajous figures.

This is a signal-level Python model, not an RTL simulation.  It models the
independent signal-source and FPGA clocks used by the wireless/automatic path:

    signal source -> oscilloscope X
    50 MHz FPGA oscillator -> 12.5 MHz DDS/DAC -> oscilloscope Y
    camera phase observations -> frequency-offset estimator -> DDS correction

The estimator tracks the slope of the wrapped Lissajous phase.  One hertz of
frequency offset produces one full Lissajous phase rotation per second.
"""

from __future__ import print_function

import argparse
import csv
import json
import math
import os
from dataclasses import asdict, dataclass, replace

import numpy as np


TWO_PI = 2.0 * math.pi


@dataclass
class SimulationConfig:
    source_frequency_hz: float = 100_000.0
    harmonic: int = 1
    nominal_sample_rate_hz: float = 12_500_000.0
    dds_accumulator_bits: int = 32
    clock_error_ppm: float = 50.0
    camera_fps: float = 30.0
    calibration_time_s: float = 3.0
    verification_time_s: float = 5.0
    phase_noise_deg: float = 0.5
    outlier_probability: float = 0.02
    outlier_noise_deg: float = 25.0
    correction_gain: float = 1.0
    target_offset_hz: float = 0.01
    seed: int = 20260729


@dataclass
class CalibrationResult:
    source_frequency_hz: float
    harmonic: int
    clock_error_ppm: float
    initial_command_hz: float
    corrected_command_hz: float
    tuning_word_before: int
    tuning_word_after: int
    output_frequency_before_hz: float
    output_frequency_after_hz: float
    true_offset_before_hz: float
    estimated_offset_before_hz: float
    true_offset_after_hz: float
    estimated_offset_after_hz: float
    target_offset_hz: float
    passed: bool
    calibration_times_s: object = None
    calibration_phase_rad: object = None
    verification_times_s: object = None
    verification_phase_rad: object = None

    def csv_row(self):
        return {
            "source_frequency_hz": self.source_frequency_hz,
            "harmonic": self.harmonic,
            "clock_error_ppm": self.clock_error_ppm,
            "initial_command_hz": self.initial_command_hz,
            "corrected_command_hz": self.corrected_command_hz,
            "tuning_word_before": self.tuning_word_before,
            "tuning_word_after": self.tuning_word_after,
            "output_frequency_before_hz": self.output_frequency_before_hz,
            "output_frequency_after_hz": self.output_frequency_after_hz,
            "true_offset_before_hz": self.true_offset_before_hz,
            "estimated_offset_before_hz": self.estimated_offset_before_hz,
            "true_offset_after_hz": self.true_offset_after_hz,
            "estimated_offset_after_hz": self.estimated_offset_after_hz,
            "target_offset_hz": self.target_offset_hz,
            "passed": self.passed,
        }


def wrap_phase(phase_rad):
    """Wrap scalar or array phase to [-pi, pi)."""
    return (phase_rad + math.pi) % TWO_PI - math.pi


def dds_frequency(command_hz, config):
    """Return physical DDS frequency and quantized tuning word.

    The tuning word is calculated with the nominal 12.5 MHz sample clock, but
    the physical output is clocked by the oscillator with its ppm error.
    """
    modulus = 1 << config.dds_accumulator_bits
    word = int(round(command_hz * modulus / config.nominal_sample_rate_hz))
    actual_sample_rate = config.nominal_sample_rate_hz * (
        1.0 + config.clock_error_ppm * 1.0e-6
    )
    physical_hz = word * actual_sample_rate / modulus
    return physical_hz, word


def simulate_camera_phase(
    offset_hz,
    duration_s,
    config,
    random_state,
    initial_phase_rad,
):
    """Generate noisy wrapped phase observations from camera frames."""
    frame_count = int(round(duration_s * config.camera_fps)) + 1
    times_s = np.arange(frame_count, dtype=float) / config.camera_fps
    true_phase = initial_phase_rad + TWO_PI * offset_hz * times_s
    measured_phase = true_phase + random_state.normal(
        loc=0.0,
        scale=math.radians(config.phase_noise_deg),
        size=frame_count,
    )

    outlier_mask = (
        random_state.uniform(size=frame_count) < config.outlier_probability
    )
    if np.any(outlier_mask):
        measured_phase[outlier_mask] += random_state.normal(
            loc=0.0,
            scale=math.radians(config.outlier_noise_deg),
            size=int(np.sum(outlier_mask)),
        )

    return times_s, wrap_phase(measured_phase)


def _robust_line_slope(times_s, values):
    """Huber iteratively reweighted least-squares line slope."""
    centered_time = times_s - np.mean(times_s)
    design = np.column_stack((np.ones_like(centered_time), centered_time))
    coefficients = np.linalg.lstsq(design, values, rcond=None)[0]

    for _ in range(6):
        residual = values - np.dot(design, coefficients)
        residual_center = np.median(residual)
        robust_sigma = 1.4826 * np.median(
            np.abs(residual - residual_center)
        )
        robust_sigma = max(float(robust_sigma), 1.0e-9)
        normalized = np.abs(residual - residual_center) / (
            1.5 * robust_sigma
        )
        weights = np.ones_like(normalized)
        large = normalized > 1.0
        weights[large] = 1.0 / normalized[large]
        root_weights = np.sqrt(weights)
        weighted_design = design * root_weights[:, None]
        weighted_values = values * root_weights
        coefficients = np.linalg.lstsq(
            weighted_design, weighted_values, rcond=None
        )[0]

    return float(coefficients[1])


def estimate_frequency_offset(times_s, wrapped_phase_rad):
    """Estimate beat frequency from wrapped phase observations.

    A median adjacent-frame estimate removes the large phase ramp first.
    Huber regression then extracts a precise residual slope without allowing
    a few image-recognition outliers to dominate the result.
    """
    if len(times_s) < 3:
        raise ValueError("At least three camera frames are required")

    delta_time = np.diff(times_s)
    wrapped_increment = np.angle(
        np.exp(1j * np.diff(wrapped_phase_rad))
    )
    coarse_slope = float(np.median(wrapped_increment / delta_time))

    detrended = wrap_phase(
        wrapped_phase_rad - coarse_slope * times_s
    )
    detrended_unwrapped = np.unwrap(detrended)
    fine_slope = _robust_line_slope(times_s, detrended_unwrapped)
    return (coarse_slope + fine_slope) / TWO_PI


def run_calibration(config, random_state=None, keep_traces=False):
    """Run one estimate-correct-verify calibration case."""
    if config.harmonic not in (1, 2):
        raise ValueError("harmonic must be 1 or 2")
    if config.source_frequency_hz < 1_000.0:
        raise ValueError("source frequency is below the 1 kHz task limit")
    if config.source_frequency_hz > 100_000.0:
        raise ValueError("source frequency is above the 100 kHz task limit")

    if random_state is None:
        random_state = np.random.RandomState(config.seed)

    desired_output_hz = config.harmonic * config.source_frequency_hz
    initial_command_hz = desired_output_hz
    output_before_hz, word_before = dds_frequency(
        initial_command_hz, config
    )
    offset_before_hz = output_before_hz - desired_output_hz

    # Wrapped phase sampled at camera_fps aliases beyond +/- camera_fps/2.
    if abs(offset_before_hz) >= config.camera_fps / 2.0:
        raise ValueError(
            "Initial offset %.6f Hz exceeds the %.3f Hz camera phase "
            "tracking limit" % (
                offset_before_hz,
                config.camera_fps / 2.0,
            )
        )

    initial_phase = random_state.uniform(-math.pi, math.pi)
    cal_times, cal_phase = simulate_camera_phase(
        offset_before_hz,
        config.calibration_time_s,
        config,
        random_state,
        initial_phase,
    )
    estimated_before_hz = estimate_frequency_offset(
        cal_times, cal_phase
    )

    corrected_command_hz = initial_command_hz - (
        config.correction_gain * estimated_before_hz
    )
    output_after_hz, word_after = dds_frequency(
        corrected_command_hz, config
    )
    offset_after_hz = output_after_hz - desired_output_hz

    phase_at_correction = (
        initial_phase
        + TWO_PI * offset_before_hz * config.calibration_time_s
    )
    verify_times, verify_phase = simulate_camera_phase(
        offset_after_hz,
        config.verification_time_s,
        config,
        random_state,
        phase_at_correction,
    )
    estimated_after_hz = estimate_frequency_offset(
        verify_times, verify_phase
    )

    passed = (
        abs(offset_after_hz) < config.target_offset_hz
        and abs(estimated_after_hz) < config.target_offset_hz
    )

    return CalibrationResult(
        source_frequency_hz=config.source_frequency_hz,
        harmonic=config.harmonic,
        clock_error_ppm=config.clock_error_ppm,
        initial_command_hz=initial_command_hz,
        corrected_command_hz=corrected_command_hz,
        tuning_word_before=word_before,
        tuning_word_after=word_after,
        output_frequency_before_hz=output_before_hz,
        output_frequency_after_hz=output_after_hz,
        true_offset_before_hz=offset_before_hz,
        estimated_offset_before_hz=estimated_before_hz,
        true_offset_after_hz=offset_after_hz,
        estimated_offset_after_hz=estimated_after_hz,
        target_offset_hz=config.target_offset_hz,
        passed=passed,
        calibration_times_s=cal_times if keep_traces else None,
        calibration_phase_rad=cal_phase if keep_traces else None,
        verification_times_s=verify_times if keep_traces else None,
        verification_phase_rad=verify_phase if keep_traces else None,
    )


def run_full_sweep(base_config):
    """Sweep the complete task band for both 1x and 2x patterns."""
    results = []
    random_state = np.random.RandomState(base_config.seed + 1)
    frequencies_hz = np.arange(1_000.0, 100_000.0 + 50.0, 100.0)
    clock_errors_ppm = (-50.0, -25.0, 25.0, 50.0)

    for harmonic in (1, 2):
        for clock_error_ppm in clock_errors_ppm:
            for source_frequency_hz in frequencies_hz:
                config = replace(
                    base_config,
                    source_frequency_hz=float(source_frequency_hz),
                    harmonic=harmonic,
                    clock_error_ppm=clock_error_ppm,
                )
                results.append(
                    run_calibration(
                        config,
                        random_state=random_state,
                        keep_traces=False,
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


def make_demo_plot(result, config, output_path):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    figure, axes = plt.subplots(2, 2, figsize=(12, 8))

    cal_phase_deg = np.degrees(
        np.unwrap(result.calibration_phase_rad)
        - np.unwrap(result.calibration_phase_rad)[0]
    )
    axes[0, 0].plot(
        result.calibration_times_s,
        cal_phase_deg,
        linewidth=1.5,
    )
    axes[0, 0].set_title(
        "Before correction: true %.4f Hz, estimated %.4f Hz"
        % (
            result.true_offset_before_hz,
            result.estimated_offset_before_hz,
        )
    )
    axes[0, 0].set_xlabel("Time (s)")
    axes[0, 0].set_ylabel("Unwrapped phase drift (deg)")
    axes[0, 0].grid(True, alpha=0.3)

    verify_phase_deg = np.degrees(
        np.unwrap(result.verification_phase_rad)
        - np.unwrap(result.verification_phase_rad)[0]
    )
    axes[0, 1].plot(
        result.verification_times_s,
        verify_phase_deg,
        linewidth=1.5,
        color="tab:green",
    )
    axes[0, 1].set_title(
        "After correction: true %.6f Hz, estimated %.6f Hz"
        % (
            result.true_offset_after_hz,
            result.estimated_offset_after_hz,
        )
    )
    axes[0, 1].set_xlabel("Time (s)")
    axes[0, 1].set_ylabel("Unwrapped phase drift (deg)")
    axes[0, 1].grid(True, alpha=0.3)

    cycle_phase = np.linspace(0.0, TWO_PI, 800)
    x_axis = np.sin(cycle_phase)
    desired_phase = math.pi / 2.0
    before_times = (0.0, 0.05, 0.10)
    after_times = (0.0, 2.5, 5.0)

    for snapshot_time in before_times:
        relative_phase = (
            desired_phase
            + TWO_PI * result.true_offset_before_hz * snapshot_time
        )
        y_axis = np.sin(
            config.harmonic * cycle_phase + relative_phase
        )
        axes[1, 0].plot(
            x_axis,
            y_axis,
            label="t=%.2fs" % snapshot_time,
        )
    axes[1, 0].set_title("Lissajous snapshots before correction")
    axes[1, 0].set_xlabel("Oscilloscope X")
    axes[1, 0].set_ylabel("Oscilloscope Y")
    axes[1, 0].axis("equal")
    axes[1, 0].grid(True, alpha=0.3)
    axes[1, 0].legend(loc="best")

    for snapshot_time in after_times:
        relative_phase = (
            desired_phase
            + TWO_PI * result.true_offset_after_hz * snapshot_time
        )
        y_axis = np.sin(
            config.harmonic * cycle_phase + relative_phase
        )
        axes[1, 1].plot(
            x_axis,
            y_axis,
            label="t=%.1fs" % snapshot_time,
        )
    axes[1, 1].set_title("Lissajous snapshots after correction")
    axes[1, 1].set_xlabel("Oscilloscope X")
    axes[1, 1].set_ylabel("Oscilloscope Y")
    axes[1, 1].axis("equal")
    axes[1, 1].grid(True, alpha=0.3)
    axes[1, 1].legend(loc="best")

    figure.suptitle(
        "Camera-based DDS frequency-offset correction (1x mode)"
    )
    figure.tight_layout(rect=(0.0, 0.0, 1.0, 0.96))
    figure.savefig(output_path, dpi=160)
    plt.close(figure)


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
        frequencies = sorted(
            set(result.source_frequency_hz for result in harmonic_results)
        )
        uncorrected_envelope = []
        corrected_envelope = []
        verified_envelope = []
        for frequency in frequencies:
            at_frequency = [
                result for result in harmonic_results
                if result.source_frequency_hz == frequency
            ]
            uncorrected_envelope.append(
                max(abs(result.true_offset_before_hz)
                    for result in at_frequency)
            )
            corrected_envelope.append(
                max(abs(result.true_offset_after_hz)
                    for result in at_frequency)
            )
            verified_envelope.append(
                max(abs(result.estimated_offset_after_hz)
                    for result in at_frequency)
            )

        axis.semilogy(
            frequencies,
            uncorrected_envelope,
            label="uncorrected true offset",
        )
        axis.semilogy(
            frequencies,
            corrected_envelope,
            label="corrected true offset",
        )
        axis.semilogy(
            frequencies,
            verified_envelope,
            label="camera-verified offset",
            alpha=0.8,
        )
        axis.axhline(
            target_offset_hz,
            color="tab:red",
            linestyle="--",
            label="0.01 Hz target",
        )
        axis.set_title("%dx output, worst of +/-25/50 ppm" % harmonic)
        axis.set_xlabel("Signal-source frequency (Hz)")
        axis.grid(True, which="both", alpha=0.3)
        axis.legend(loc="best", fontsize=8)

    axes[0].set_ylabel("Absolute frequency offset (Hz)")
    figure.suptitle(
        "Full 1-100 kHz sweep, 100 Hz step, 30 fps camera"
    )
    figure.tight_layout(rect=(0.0, 0.0, 1.0, 0.94))
    figure.savefig(output_path, dpi=160)
    plt.close(figure)


def write_summary_json(config, demo_result, sweep_results, output_path):
    max_true_residual = max(
        abs(result.true_offset_after_hz) for result in sweep_results
    )
    max_verified_residual = max(
        abs(result.estimated_offset_after_hz)
        for result in sweep_results
    )
    failed_cases = sum(not result.passed for result in sweep_results)
    summary = {
        "model": {
            "fpga_pl_clock_hz": 50_000_000.0,
            "dds_dac_sample_rate_hz": config.nominal_sample_rate_hz,
            "dds_accumulator_bits": config.dds_accumulator_bits,
            "camera_fps": config.camera_fps,
            "calibration_time_s": config.calibration_time_s,
            "verification_time_s": config.verification_time_s,
            "target_offset_hz": config.target_offset_hz,
        },
        "demo": demo_result.csv_row(),
        "sweep": {
            "frequency_start_hz": 1_000.0,
            "frequency_stop_hz": 100_000.0,
            "frequency_step_hz": 100.0,
            "harmonics": [1, 2],
            "clock_errors_ppm": [-50.0, -25.0, 25.0, 50.0],
            "case_count": len(sweep_results),
            "failed_case_count": failed_cases,
            "max_true_residual_hz": max_true_residual,
            "max_camera_verified_residual_hz": max_verified_residual,
        },
    }
    with open(output_path, "w", encoding="utf-8") as output_file:
        json.dump(summary, output_file, indent=2, ensure_ascii=False)
        output_file.write("\n")


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Simulate camera-based correction of signal-source/FPGA "
            "frequency offset."
        )
    )
    parser.add_argument(
        "--source-frequency-hz",
        type=float,
        default=100_000.0,
        help="Demo signal-source frequency (default: 100000)",
    )
    parser.add_argument(
        "--clock-error-ppm",
        type=float,
        default=50.0,
        help="Demo FPGA clock error in ppm (default: +50)",
    )
    parser.add_argument(
        "--phase-noise-deg",
        type=float,
        default=0.5,
        help="One-sigma camera phase noise in degrees (default: 0.5)",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=20260729,
        help="Random seed",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help="Output directory (default: phase sim/output)",
    )
    parser.add_argument(
        "--skip-sweep",
        action="store_true",
        help="Run only the single demonstration case",
    )
    parser.add_argument(
        "--no-plots",
        action="store_true",
        help="Do not generate PNG plots",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    script_dir = os.path.dirname(os.path.abspath(__file__))
    output_dir = (
        os.path.abspath(args.output_dir)
        if args.output_dir
        else os.path.join(script_dir, "output")
    )
    if not os.path.isdir(output_dir):
        os.makedirs(output_dir)

    config = SimulationConfig(
        source_frequency_hz=args.source_frequency_hz,
        harmonic=1,
        clock_error_ppm=args.clock_error_ppm,
        phase_noise_deg=args.phase_noise_deg,
        seed=args.seed,
    )
    random_state = np.random.RandomState(config.seed)
    demo_result = run_calibration(
        config,
        random_state=random_state,
        keep_traces=True,
    )

    print(
        "[DEMO] source=%.1f Hz, clock=%+.1f ppm"
        % (config.source_frequency_hz, config.clock_error_ppm)
    )
    print(
        "[DEMO] offset before: true=%+.6f Hz, estimated=%+.6f Hz"
        % (
            demo_result.true_offset_before_hz,
            demo_result.estimated_offset_before_hz,
        )
    )
    print(
        "[DEMO] offset after : true=%+.6f Hz, verified=%+.6f Hz"
        % (
            demo_result.true_offset_after_hz,
            demo_result.estimated_offset_after_hz,
        )
    )
    print(
        "[%s] demo residual target: |offset| < %.3f Hz"
        % (
            "PASS" if demo_result.passed else "FAIL",
            config.target_offset_hz,
        )
    )

    if not args.no_plots:
        make_demo_plot(
            demo_result,
            config,
            os.path.join(output_dir, "calibration_demo.png"),
        )

    if args.skip_sweep:
        return 0 if demo_result.passed else 1

    sweep_results = run_full_sweep(config)
    write_sweep_csv(
        sweep_results,
        os.path.join(output_dir, "frequency_sweep.csv"),
    )
    if not args.no_plots:
        make_sweep_plot(
            sweep_results,
            config.target_offset_hz,
            os.path.join(output_dir, "frequency_sweep.png"),
        )
    write_summary_json(
        config,
        demo_result,
        sweep_results,
        os.path.join(output_dir, "summary.json"),
    )

    failed_cases = [result for result in sweep_results if not result.passed]
    max_true_residual = max(
        abs(result.true_offset_after_hz) for result in sweep_results
    )
    max_verified_residual = max(
        abs(result.estimated_offset_after_hz)
        for result in sweep_results
    )
    print(
        "[SWEEP] %d cases, %d failures"
        % (len(sweep_results), len(failed_cases))
    )
    print(
        "[SWEEP] maximum true residual     = %.6f Hz"
        % max_true_residual
    )
    print(
        "[SWEEP] maximum verified residual = %.6f Hz"
        % max_verified_residual
    )
    print("[OUTPUT] %s" % output_dir)

    return 0 if demo_result.passed and not failed_cases else 1


if __name__ == "__main__":
    raise SystemExit(main())
