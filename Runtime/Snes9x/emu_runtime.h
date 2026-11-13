// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#ifndef EMU_RUNTIME_H
#define EMU_RUNTIME_H
#include <stdint.h>
#if defined(_WIN32)
#define EMU_API __declspec(dllexport)
#else
#define EMU_API __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
#define EMU_RUNTIME_ABI 1u
typedef struct emu_runtime emu_runtime;
enum emu_result { EMU_OK=0, EMU_ARGUMENT=1, EMU_ABI=2, EMU_BUSY=3,
    EMU_ROM=4, EMU_INTERNAL=5, EMU_BUFFER=6, EMU_STATE=7, EMU_RESTART_REQUIRED=8 };
/* Bit order: Up Down Left Right A B X Y L R Start Select. */
typedef struct emu_frame {
    const uint16_t *video; /* RGB565, native endian; pitch is in pixels. */
    uint32_t width, height, pitch;
    const int16_t *audio; /* interleaved stereo, 32040 Hz */
    uint32_t audio_frames;
} emu_frame;
/* All calls on the same host thread; one lifetime per process (Snes9x globals).
   ABI 1 general profile: SNES images, zero/factory SRAM,
   two joypads, no cheats/patches/sidecar media. ROM bytes are copied.
   Views expire on step, restore or destroy. Callers own snapshot buffers. */
EMU_API uint32_t emu_runtime_abi(void);
EMU_API const char *emu_runtime_profile(void);
EMU_API int32_t emu_create(uint32_t abi, const uint8_t *rom, uint32_t length, emu_runtime **out);
EMU_API uint32_t emu_frame_duration_us(emu_runtime *runtime);
EMU_API void emu_destroy(emu_runtime *runtime);
EMU_API int32_t emu_step(emu_runtime *runtime, uint16_t player1, uint16_t player2, emu_frame *out);
/* Optional ABI 1 extension. NX_NETPLAY_PLAYERS selects 2..5 before create.
   The selected topology is part of the profile and cannot change mid-session. */
EMU_API int32_t emu_step_players(emu_runtime *runtime, const uint16_t *players, uint32_t count, emu_frame *out);
EMU_API int32_t emu_state_size(emu_runtime *runtime, uint32_t *size);
EMU_API int32_t emu_state_copy(emu_runtime *runtime, uint8_t *out, uint32_t capacity);
/* State format: EMUSNES1 header (16 bytes) plus unmodified Snes9x snapshot.
   Header holds raw length (LE32), CPU OpenBus byte, then three zero bytes.
   Trusted local snapshots from this exact ROM/build/profile only. Not a network
   deserializer. Snapshots contain machine state, not queued host audio/video.
   On restore, presentation queues are discarded; next step provides video. */
EMU_API int32_t emu_state_restore(emu_runtime *runtime, const uint8_t *data, uint32_t size);
#ifdef __cplusplus
}
#endif
#endif
