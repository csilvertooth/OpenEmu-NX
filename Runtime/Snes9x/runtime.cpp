// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#include "emu_runtime.h"
#include "snes9x.h"
#include "memmap.h"
#include "gfx.h"
#include "ppu.h"
#include "apu/apu.h"
#include "controls.h"
#include "snapshot.h"
#include "display.h"
#include "conffile.h"
#include "sha256.h"
#include "getset.h"
#include <vector>
#include <memory>
#include <cstring>
#include <cstdio>

struct emu_runtime {
    std::vector<uint16_t> video;
    std::vector<int16_t> audio;
    uint32_t state_size = 0;
    bool memory = false, apu = false, graphics = false, failed = false;
};
static emu_runtime *active = nullptr;
static bool used = false;
static bool valid(emu_runtime *r) { return r && r == active && !r->failed; }
static void samples(void *context) {
    auto *r = static_cast<emu_runtime *>(context);
    int count = S9xGetSampleCount();
    if (count <= 0) return;
    size_t start = r->audio.size();
    r->audio.resize(start + count);
    if (!S9xMixSamples(reinterpret_cast<uint8 *>(r->audio.data() + start), count))
        r->failed = true;
}
static void cleanup(emu_runtime *r) {
    S9xSetSamplesAvailableCallback(nullptr, nullptr);
    S9xUnmapAllControls();
    if (r->graphics) S9xGraphicsDeinit();
    if (r->apu) S9xDeinitAPU();
    if (r->memory) Memory.Deinit();
}
uint32_t emu_runtime_abi(void) { return EMU_RUNTIME_ABI; }
const char *emu_runtime_profile(void) { return "snes9x-1.63-smk-ntsc-v1-abi1"; }
int32_t emu_create(uint32_t abi, const uint8_t *rom, uint32_t length, emu_runtime **out) {
    if (!out) return EMU_ARGUMENT;
    *out = nullptr;
    if (abi != EMU_RUNTIME_ABI) return EMU_ABI;
    if (!rom || !length) return EMU_ARGUMENT;
    if (active) return EMU_BUSY;
    if (used) return EMU_RESTART_REQUIRED;
    if (length > 8u*1024u*1024u) return EMU_ROM;
    const uint8_t expected[32] = {0x2a,0xda,0x89,0x19,0x68,0x80,0x87,0xbe,
        0x60,0xa6,0xa4,0x8c,0xac,0xe8,0xf8,0x77,0xad,0xd6,0x0c,0x45,0xd2,0xe5,
        0xd0,0x9e,0x24,0x42,0xfa,0xa5,0x5b,0xe6,0x2a,0x49};
    uint8_t hash[32]; sha256sum(const_cast<uint8_t *>(rom), length, hash);
    if (memcmp(hash, expected, 32)) return EMU_ROM;
    std::unique_ptr<emu_runtime> r;
    try {
        r.reset(new emu_runtime);
        r->video.resize(MAX_SNES_WIDTH * MAX_SNES_HEIGHT);
        r->audio.reserve(8192);
        used = true;
        memset(&Settings, 0, sizeof(Settings));
        Settings.MouseMaster = Settings.SuperScopeMaster = true;
        Settings.MultiPlayer5Master = Settings.JustifierMaster = true;
        Settings.SoundPlaybackRate = Settings.SoundInputRate = 32040;
        Settings.DynamicRateLimit = 5;
        Settings.Transparency = true;
        Settings.DontSaveOopsSnapshot = Settings.NoPatch = true;
        Settings.InterpolationMethod = DSP_INTERPOLATION_GAUSSIAN;
        Settings.OneClockCycle = ONE_CYCLE;
        Settings.OneSlowClockCycle = SLOW_ONE_CYCLE;
        Settings.TwoClockCycles = TWO_CYCLES;
        Settings.SuperFXClockMultiplier = 100;
        Settings.BlockInvalidVRAMAccessMaster = true;
        Settings.HDMATimingHack = 100;
        Settings.MaxSpriteTilesPerLine = 34;
        GFX.InfoString.clear(); GFX.InfoStringTimeout = 0;
        S9xUnmapAllControls();
        const char *keys[] = {"Up","Down","Left","Right","A","B","X","Y","L","R","Start","Select"};
        for (int p=1; p<=2; ++p) for (int b=0; b<12; ++b) {
            char command[32]; snprintf(command, sizeof(command), "Joypad%d %s", p, keys[b]);
            S9xMapButton((p<<16)|b, S9xGetCommandT(command), false);
        }
        r->memory = Memory.Init();
        if (r->memory) r->apu = S9xInitAPU();
        if (r->apu) r->graphics = S9xGraphicsInit();
        if (!r->graphics || !S9xInitSound(100)) { cleanup(r.get()); return EMU_INTERNAL; }
        S9xSetSamplesAvailableCallback(samples, r.get());
        if (!Memory.LoadROMMem(rom, length)) { cleanup(r.get()); return EMU_ROM; }
        S9xSetController(0, CTL_JOYPAD, 0, 0, 0, 0);
        S9xSetController(1, CTL_JOYPAD, 1, 0, 0, 0);
        GFX.Screen = r->video.data();
        r->state_size = 16 + S9xFreezeSize();
        active = r.release(); *out = active;
        return EMU_OK;
    } catch (...) { if (r) cleanup(r.get()); return EMU_INTERNAL; }
}
void emu_destroy(emu_runtime *r) {
    if (!r || r != active) return;
    cleanup(r); active = nullptr; delete r;
}
int32_t emu_step(emu_runtime *r, uint16_t p1, uint16_t p2, emu_frame *out) {
    if (!valid(r) || !out || ((p1|p2)&0xf000)) return EMU_ARGUMENT;
    *out = {};
    try {
        // Reapply every button, including releases, so restoring needs no hidden
        // host-side previous-input cache. Plain joypads have no command repeats.
        for (int b=0; b<12; ++b) {
            S9xReportButton((1<<16)|b, (p1>>b)&1);
            S9xReportButton((2<<16)|b, (p2>>b)&1);
        }
        r->audio.clear(); GFX.Screen = r->video.data();
        IPPU.RenderThisFrame = true;
        S9xMainLoop();
        if (r->failed) return EMU_INTERNAL;
        out->video = r->video.data(); out->width = IPPU.RenderedScreenWidth;
        out->height = IPPU.RenderedScreenHeight; out->pitch = GFX.RealPPL;
        out->audio = r->audio.data(); out->audio_frames = uint32_t(r->audio.size()/2);
        return EMU_OK;
    } catch (...) { r->failed = true; return EMU_INTERNAL; }
}
int32_t emu_state_size(emu_runtime *r, uint32_t *size) {
    if (!valid(r) || !size) return EMU_ARGUMENT;
    *size = r->state_size; return EMU_OK;
}
int32_t emu_state_copy(emu_runtime *r, uint8_t *out, uint32_t capacity) {
    if (!valid(r) || !out) return EMU_ARGUMENT;
    if (capacity < r->state_size) return EMU_BUFFER;
    try {
        memset(out, 0, r->state_size);
        memcpy(out, "EMUSNES1", 8);
        uint32_t raw_size = r->state_size - 16;
        for (int i=0; i<4; ++i) out[8+i] = uint8_t(raw_size >> (8*i));
        out[12] = OpenBus;
        return S9xFreezeGameMem(out+16, raw_size) ? EMU_OK : EMU_INTERNAL;
    } catch (...) { r->failed = true; return EMU_INTERNAL; }
}
int32_t emu_state_restore(emu_runtime *r, const uint8_t *data, uint32_t size) {
    if (!valid(r) || !data) return EMU_ARGUMENT;
    if (size != r->state_size || memcmp(data, "EMUSNES1", 8) || data[13] || data[14] || data[15])
        return EMU_STATE;
    uint32_t raw_size = 0;
    for (int i=0; i<4; ++i) raw_size |= uint32_t(data[8+i]) << (8*i);
    if (raw_size != size-16) return EMU_STATE;
    try {
        if (S9xUnfreezeGameMem(data+16, raw_size) != SUCCESS) return EMU_STATE;
        // Snes9x's snapshot omits this execution-relevant global.
        OpenBus = data[12];
        r->audio.clear(); S9xClearSamples();
        std::fill(r->video.begin(), r->video.end(), 0);
        GFX.Screen = r->video.data();
        return EMU_OK;
    } catch (...) { r->failed = true; return EMU_INTERNAL; }
}

// Port callbacks: no UI, filesystem saves, host clock pacing or input polling.
bool8 S9xOpenSnapshotFile(const char *, bool8, STREAM *) { return false; }
void S9xCloseSnapshotFile(STREAM) {}
void S9xMessage(int, int, const char *message) { fprintf(stderr, "[Snes9x] %s\n", message); }
// /dev/null is a file, so child paths cannot resolve to accidental sidecars.
std::string S9xGetDirectory(enum s9x_getdirtype) { return "/dev/null"; }
std::string S9xGetFilenameInc(std::string, enum s9x_getdirtype) { return ""; }
void S9xAutoSaveSRAM(void) {}
void S9xSyncSpeed(void) { IPPU.RenderThisFrame = true; }
bool8 S9xOpenSoundDevice(void) { return true; }
bool8 S9xInitUpdate(void) { return true; }
bool8 S9xDeinitUpdate(int, int) { return true; }
bool8 S9xContinueUpdate(int, int) { return true; }
const char *S9xStringInput(const char *) { return nullptr; }
bool S9xPollButton(uint32, bool *pressed) { if (pressed) *pressed=false; return false; }
bool S9xPollPointer(uint32, int16 *x, int16 *y) { if(x)*x=0; if(y)*y=0; return false; }
bool S9xPollAxis(uint32, int16 *value) { if(value)*value=0; return false; }
bool8 S9xDoScreenshot(int, int) { return false; }
void S9xToggleSoundChannel(int) {}
void SetInfoDlgColor(unsigned char, unsigned char, unsigned char) {}
void S9xExit(void) { if(active) active->failed=true; }
void S9xHandlePortCommand(s9xcommand_t, int16, int16) {}
void S9xExtraUsage(void) {}
void S9xParseArg(char **, int &, int) {}
void S9xParsePortConfig(ConfigFile &, int) {}
