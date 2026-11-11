#!/usr/bin/env python3
# Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
"""Compare every serialized Snes9x state from independent, isolated processes."""
import argparse
import hashlib
import json
import platform
import re
import subprocess
import sys
from pathlib import Path


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def make_trace(path, frames):
    # Fixed, recorded inputs; this is a synthetic exercise, not a certified race replay.
    with path.open('x') as stream:
        for frame in range(1, frames + 1):
            p1 = p2 = 0
            # Menu navigation followed by simultaneous acceleration and steering.
            if 180 <= frame < 190: p1 = 1 << 10  # Start
            if 300 <= frame < 310: p1 = 1 << 1   # Down
            if 420 <= frame < 430 or 600 <= frame < 610: p1 = 1 << 5
            if 480 <= frame < 490 or 660 <= frame < 670: p2 = 1 << 5
            if frame >= 900:
                phase = (frame // 120) % 4
                p1 = (1 << 5) | (1 << (2 if phase < 2 else 3))
                p2 = (1 << 5) | (1 << (3 if phase < 2 else 2))
                if frame % 240 < 12: p1 |= 1 << 4
                if frame % 180 < 12: p2 |= 1 << 9
            stream.write(f'{frame} {p1} {p2}\n')


def validate_trace(path):
    count = 0
    with path.open() as stream:
        for count, line in enumerate(stream, 1):
            fields = line.split()
            if len(fields) != 3 or not all(x.isdecimal() for x in fields):
                raise ValueError(f'invalid trace row {count}')
            frame, p1, p2 = map(int, fields)
            if frame != count or not 0 <= p1 <= 4095 or not 0 <= p2 <= 4095:
                raise ValueError(f'invalid trace frame/mask at row {count}')
    if not 1 <= count <= 10_000_000:
        raise ValueError('trace must contain 1..10000000 frames')
    return count


def read_hashes(path, frames):
    rows = []
    with path.open() as stream:
        for expected, line in enumerate(stream):
            fields = line.split()
            if len(fields) != 3 or not fields[0].isdecimal() or not fields[1].isdecimal():
                raise ValueError(f'invalid hash row in {path}')
            if int(fields[0]) != expected or int(fields[1]) <= 0 or not re.fullmatch('[0-9a-f]{64}', fields[2]):
                raise ValueError(f'invalid hash sequence in {path}')
            rows.append((int(fields[1]), fields[2]))
    if len(rows) != frames + 1:
        raise ValueError(f'incomplete replay {path}: got {len(rows)}, expected {frames + 1}')
    return rows


def first_difference(a, b):
    if len(a) != len(b): raise ValueError('incomplete comparison')
    return next((n for n, (x, y) in enumerate(zip(a, b)) if x != y), None)


def run_pair(args, traces, prefix, dump=None):
    processes = []
    handles = []
    outputs = [args.output / f'{prefix}-{side}.hashes' for side in ('a', 'b')]
    try:
        for trace, output in zip(traces, outputs):
            log = output.with_suffix('.log').open('x')
            handles.append(log)
            command = [str(args.runner), str(args.core), str(args.rom), str(trace), str(output)]
            if dump is not None: command.append(str(dump))
            env = dict(__import__('os').environ)
            if getattr(args, 'capture_frames', None):
                env['SNES_REPLAY_CAPTURE_DIR'] = str(args.output / f'{prefix}-{output.stem[-1]}-captures')
                env['SNES_REPLAY_CAPTURE_FRAMES'] = args.capture_frames
            processes.append(subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, env=env))
        for process in processes:
            if process.wait(timeout=args.timeout) != 0:
                raise RuntimeError(f'{prefix}: replay failed; inspect process logs')
    finally:
        for process in processes:
            if process.poll() is None: process.kill()
        for process in processes: process.wait()
        for handle in handles: handle.close()
    return outputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('runner', 'core', 'rom', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--trace', type=Path)
    parser.add_argument('--frames', type=int, default=100000)
    parser.add_argument('--repetitions', type=int, default=3)
    parser.add_argument('--timeout', type=int, default=1200)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--capture-frames', help='Comma-separated post-step frames to capture in each process')
    args = parser.parse_args()
    if not 1 <= args.frames <= 10_000_000 or args.repetitions < 1 or args.timeout < 1:
        parser.error('positive bounded frames, repetitions and timeout required')
    for name in ('runner', 'core', 'rom', 'output'):
        setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=False)
    report = {'status': 'running', 'platform': platform.platform(), 'machine': platform.machine(),
              'runner_sha256': sha(args.runner), 'rom_sha256': sha(args.rom),
              'core_sha256': sha(args.core / 'Contents/MacOS/SNES9x'),
              'framework_sha256': sha(args.core.parent / 'OpenEmuBase.framework/OpenEmuBase'),
              'hash_domain': 'complete unmodified Snes9x serialized snapshot; SHA-256 every frame including frame 0',
              'limitations': 'Per-host same-build comparison. Gameplay and cross-machine coverage require separate evidence.', 'runs': []}
    try:
        trace = args.output / 'inputs.txt'
        if args.trace: trace.write_bytes(args.trace.read_bytes())
        else: make_trace(trace, 180 if args.self_test else args.frames)
        frames = validate_trace(trace)
        if args.capture_frames:
            capture_values = args.capture_frames.split(',')
            if not all(x.isdecimal() and 1 <= int(x) <= frames for x in capture_values):
                raise ValueError('capture frames must be within the trace')
            report['capture_frames'] = list(map(int, capture_values))
        report.update(frames=frames, trace_sha256=sha(trace))
        reference = None
        for repeat in range(1 if args.self_test else args.repetitions):
            outputs = run_pair(args, [trace, trace], f'run-{repeat + 1}')
            a, b = [read_hashes(p, frames) for p in outputs]
            mismatch = first_difference(a, b)
            if mismatch is None and reference is not None: mismatch = first_difference(reference, a)
            report['runs'].append({'repeat': repeat + 1, 'first_mismatch': mismatch,
                                   'final_sha256': a[-1][1], 'initial_sha256': a[0][1]})
            if mismatch is not None:
                # Raw state files stay local; no ROM data is uploaded by this script.
                run_pair(args, [trace, trace], f'diagnostic-{repeat + 1}', dump=mismatch)
                raise RuntimeError(f'first state divergence at frame {mismatch}; inspect diagnostic snapshots')
            reference = a
            print(f'PASS pair {repeat + 1}: {frames} frames plus initial state', flush=True)
        if args.self_test:
            altered = args.output / 'altered-inputs.txt'
            rows = trace.read_text().splitlines()
            frame, p1, p2 = map(int, rows[60].split())
            rows[60] = f'{frame} {p1 ^ 16} {p2}'
            altered.write_text('\n'.join(rows) + '\n')
            outputs = run_pair(args, [trace, altered], 'negative-control')
            mismatch = first_difference(*[read_hashes(p, frames) for p in outputs])
            if mismatch is None: raise RuntimeError('negative control missed altered controller input')
            report['negative_control_first_mismatch'] = mismatch
            truncated = args.output / 'truncated.hashes'
            truncated.write_text(outputs[0].read_text().splitlines()[0] + '\n')
            try: read_hashes(truncated, frames)
            except ValueError: pass
            else: raise RuntimeError('incomplete log accepted')
            print(f'PASS negative controls: input divergence at {mismatch}; truncated log rejected', flush=True)
        report['status'] = 'passed'
    except Exception as error:
        report.update(status='failed', error=str(error))
        raise
    finally:
        (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    try: main()
    except Exception as error:
        print(f'FAIL: {error}', file=sys.stderr)
        sys.exit(1)
