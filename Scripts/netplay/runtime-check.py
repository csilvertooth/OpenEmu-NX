#!/usr/bin/env python3
# Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
"""Test the C ABI, compare the plugin oracle, and replay after trusted restores."""
import argparse
import ctypes as C
import hashlib
import json
import platform
from pathlib import Path

class Frame(C.Structure):
    _fields_ = [('video', C.POINTER(C.c_uint16)), ('width', C.c_uint32),
                ('height', C.c_uint32), ('pitch', C.c_uint32),
                ('audio', C.POINTER(C.c_int16)), ('audio_frames', C.c_uint32)]

def digest(data):
    return hashlib.sha256(data).hexdigest()

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library', required=True, type=Path)
    p.add_argument('--rom', required=True, type=Path)
    p.add_argument('--trace', required=True, type=Path)
    p.add_argument('--reference', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--frames', type=int, default=12000)
    args = p.parse_args()
    if args.frames < 9000:
        p.error('at least 9000 frames needed for gameplay restore checks')
    args.output.mkdir(parents=True, exist_ok=False)
    lib = C.CDLL(str(args.library.resolve()))
    ptr, u32, u16, buf = C.c_void_p, C.c_uint32, C.c_uint16, C.POINTER(C.c_uint8)
    signatures = {
        'emu_runtime_abi': ([], u32), 'emu_runtime_profile': ([], C.c_char_p),
        'emu_create': ([u32, buf, u32, C.POINTER(ptr)], C.c_int32),
        'emu_destroy': ([ptr], None),
        'emu_step': ([ptr, u16, u16, C.POINTER(Frame)], C.c_int32),
        'emu_state_size': ([ptr, C.POINTER(u32)], C.c_int32),
        'emu_state_copy': ([ptr, buf, u32], C.c_int32),
        'emu_state_restore': ([ptr, buf, u32], C.c_int32),
    }
    for name, (inputs, result) in signatures.items():
        fn = getattr(lib, name); fn.argtypes = inputs; fn.restype = result
    def check(code, expected=0):
        if code != expected:
            raise AssertionError(f'ABI returned {code}, expected {expected}')
    rom = (C.c_uint8 * args.rom.stat().st_size).from_buffer_copy(args.rom.read_bytes())
    handle = ptr()
    assert lib.emu_runtime_abi() == 1
    check(lib.emu_create(2, rom, len(rom), C.byref(handle)), 2)
    check(lib.emu_create(1, None, 0, C.byref(handle)), 1)
    wrong_rom = (C.c_uint8 * 1)(0)
    check(lib.emu_create(1, wrong_rom, 1, C.byref(handle)), 4)
    check(lib.emu_create(1, rom, len(rom), C.byref(handle)))
    try:
        other = ptr()
        check(lib.emu_create(1, rom, len(rom), C.byref(other)), 3)
        assert not other.value
        size = u32(); check(lib.emu_state_size(handle, C.byref(size)))
        state = (C.c_uint8 * size.value)()
        frame = Frame()
        check(lib.emu_step(None, 0, 0, C.byref(frame)), 1)
        check(lib.emu_step(handle, 4096, 0, C.byref(frame)), 1)
        check(lib.emu_state_copy(handle, state, size.value-1), 6)
        def snapshot():
            check(lib.emu_state_copy(handle, state, size.value))
            return bytes(state)
        initial = snapshot()
        assert initial[:8] == b'EMUSNES1' and int.from_bytes(initial[8:12], 'little') == size.value-16
        # An execution-relevant omitted field must survive restore verbatim.
        # Alter only the wrapper's OpenBus byte; raw core bytes remain unchanged.
        modified = bytearray(initial); modified[12] ^= 255
        changed = (C.c_uint8 * size.value).from_buffer_copy(modified)
        check(lib.emu_state_restore(handle, changed, size.value))
        assert snapshot()[12] == modified[12], 'CPU OpenBus was not restored'
        original = (C.c_uint8 * size.value).from_buffer_copy(initial)
        check(lib.emu_state_restore(handle, original, size.value))
        # Restore may refresh derived fields; retain the original frame-zero oracle
        # by using this restored frame-zero state only if it matches byte-for-byte.
        assert snapshot() == initial, 'frame-zero restore changed canonical state'
        check(lib.emu_state_restore(handle, state, size.value-1), 7)
        assert snapshot() == initial, 'truncation changed state'
        state[0] ^= 255
        check(lib.emu_state_restore(handle, state, size.value), 7)
        assert snapshot() == initial, 'bad magic changed state'
        trace = [tuple(map(int, s.split())) for s in args.trace.read_text().splitlines()[:args.frames]]
        assert len(trace) == args.frames
        for i, row in enumerate(trace, 1):
            assert len(row) == 3 and row[0] == i and all(0 <= v < 4096 for v in row[1:])
        reference = args.reference.read_text().splitlines()[:args.frames+1]
        assert len(reference) == args.frames+1
        saved = {0: initial}; hashes = []; videos = []; audio_total = 0
        media = hashlib.sha256()
        def advance(row):
            check(lib.emu_step(handle, row[1], row[2], C.byref(frame)))
            assert 0 < frame.width <= frame.pitch <= 512 and 0 < frame.height <= 478
            assert frame.audio_frames < 4096
            addr = C.cast(frame.video, ptr).value
            video = b''.join(C.string_at(addr+y*frame.pitch*2, frame.width*2) for y in range(frame.height))
            audio = C.string_at(frame.audio, frame.audio_frames*4)
            return digest(video), digest(audio)
        with (args.output/'states.hashes').open('x') as log, (args.output/'media.hashes').open('x') as av:
            for index in range(args.frames+1):
                if index:
                    vh, ah = advance(trace[index-1])
                    videos.append(vh); audio_total += frame.audio_frames
                    media_line = f'{index} {frame.width} {frame.height} {vh} {frame.audio_frames} {ah}\n'
                    av.write(media_line); media.update(media_line.encode())
                raw = snapshot(); sha = digest(raw); hashes.append(sha)
                line = f'{index} {len(raw)} {sha}'
                log.write(line+'\n')
                oracle_line = f'{index} {len(raw)-16} {digest(raw[16:])}'
                if oracle_line != reference[index]:
                    (args.output/f'mismatch-{index}.state').write_bytes(raw)
                    raise AssertionError(f'plugin oracle mismatch at frame {index}: {oracle_line} != {reference[index]}')
                if index in (6000, 7000): saved[index] = raw
        assert audio_total > 0
        restore_results = []
        for start, count in [(0,180), (6000,1500), (7000,1500)]:
            raw = (C.c_uint8 * size.value).from_buffer_copy(saved[start])
            check(lib.emu_state_restore(handle, raw, size.value))
            for index in range(start+1, start+count+1):
                vh, _ = advance(trace[index-1])
                assert digest(snapshot()) == hashes[index], f'restore {start}: state diverged at {index}'
                assert vh == videos[index-1], f'restore {start}: video diverged at {index}'
            restore_results.append({'saved_frame': start, 'replayed_frames': count, 'state_and_video_match': True})
        report = {'result':'PASS', 'profile':lib.emu_runtime_profile().decode(),
                  'platform':platform.platform(), 'frames':args.frames,
                  'library_sha256':digest(args.library.read_bytes()), 'rom_sha256':digest(bytes(rom)),
                  'trace_sha256':digest(args.trace.read_bytes()), 'state_size':size.value,
                  'states_sha256':digest((args.output/'states.hashes').read_bytes()),
                  'media_sha256':media.hexdigest(), 'audio_frames':audio_total,
                  'restore_checks':restore_results, 'invalid_arguments_rejected':True, 'open_bus_restore_verified':True,
                  'oracle_domain':'unmodified snapshot payload; runtime hashes include the 16-byte wrapper',
                  'limitations':['Restore discards host audio queue; audio continuity across restore is not promised.',
                                 'Same-build SMK profile only; no network or physical controller test.']}
    finally:
        lib.emu_destroy(handle)
    check(lib.emu_create(1, rom, len(rom), C.byref(handle)), 8)
    report['second_lifetime_rejected'] = True
    (args.output/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report), flush=True)

if __name__ == '__main__':
    main()
