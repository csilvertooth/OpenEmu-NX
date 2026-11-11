#!/usr/bin/env python3
# Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
"""Expand a frame-interval input plan; overlapping events combine button masks."""
import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('plan', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    plan = json.loads(args.plan.read_text())
    frames = plan['frames']
    if type(frames) is not int or not 1 <= frames <= 10_000_000:
        raise ValueError('invalid frame count')
    events = plan['events']
    for event in events:
        if len(event) != 4 or any(type(x) is not int for x in event):
            raise ValueError('event must be [start, exclusive_end, player, button_mask]')
        start, end, player, mask = event
        if not (1 <= start < end <= frames + 1 and player in (1, 2) and 0 <= mask <= 4095):
            raise ValueError('invalid event range, player or mask')
    with args.output.open('x') as stream:
        for frame in range(1, frames + 1):
            masks = [0, 0]
            for start, end, player, mask in events:
                if start <= frame < end:
                    masks[player - 1] |= mask
            stream.write(f'{frame} {masks[0]} {masks[1]}\n')


if __name__ == '__main__':
    main()
