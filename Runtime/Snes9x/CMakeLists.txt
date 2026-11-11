# Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
cmake_minimum_required(VERSION 3.20)
project(emu_snes_runtime LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)
set(CORE "${CMAKE_CURRENT_SOURCE_DIR}/../../SNES9x/src")
add_library(emu_snes SHARED runtime.cpp
    ${CORE}/apu/apu.cpp
    ${CORE}/bml.cpp
    ${CORE}/bsx.cpp
    ${CORE}/c4.cpp
    ${CORE}/c4emu.cpp
    ${CORE}/cheats.cpp
    ${CORE}/cheats2.cpp
    ${CORE}/clip.cpp
    ${CORE}/conffile.cpp
    ${CORE}/controls.cpp
    ${CORE}/cpu.cpp
    ${CORE}/cpuexec.cpp
    ${CORE}/cpuops.cpp
    ${CORE}/crosshairs.cpp
    ${CORE}/debug.cpp
    ${CORE}/dma.cpp
    ${CORE}/dsp.cpp
    ${CORE}/dsp1.cpp
    ${CORE}/dsp2.cpp
    ${CORE}/dsp3.cpp
    ${CORE}/dsp4.cpp
    ${CORE}/fscompat.cpp
    ${CORE}/fxdbg.cpp
    ${CORE}/fxemu.cpp
    ${CORE}/fxinst.cpp
    ${CORE}/gfx.cpp
    ${CORE}/globals.cpp
    ${CORE}/logger.cpp
    ${CORE}/memmap.cpp
    ${CORE}/movie.cpp
    ${CORE}/msu1.cpp
    ${CORE}/obc1.cpp
    ${CORE}/ppu.cpp
    ${CORE}/sa1.cpp
    ${CORE}/sa1cpu.cpp
    ${CORE}/sdd1.cpp
    ${CORE}/sdd1emu.cpp
    ${CORE}/apu/bapu/dsp/sdsp.cpp
    ${CORE}/seta.cpp
    ${CORE}/seta010.cpp
    ${CORE}/seta011.cpp
    ${CORE}/seta018.cpp
    ${CORE}/sha256.cpp
    ${CORE}/apu/bapu/smp/smp.cpp
    ${CORE}/apu/bapu/smp/smp_state.cpp
    ${CORE}/snapshot.cpp
    ${CORE}/snes9x.cpp
    ${CORE}/spc7110.cpp
    ${CORE}/srtc.cpp
    ${CORE}/stream.cpp
    ${CORE}/tile.cpp
    ${CORE}/tileimpl-h2x1.cpp
    ${CORE}/tileimpl-n1x1.cpp
    ${CORE}/tileimpl-n2x1.cpp
)
target_include_directories(emu_snes PRIVATE "${CORE}" "${CORE}/apu/bapu")
target_compile_definitions(emu_snes PRIVATE HAVE_STRINGS_H HAVE_INTTYPES_H HAVE_STDINT_H RIGHTSHIFT_IS_SAR)
target_include_directories(emu_snes PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
# Exercise the public header as C, not just through its C++ implementation.
add_library(emu_c_header OBJECT header_check.c)
# A fresh helper process computes real lobby compatibility without consuming the
# app's future game-runtime lifetime or touching battery saves.
add_executable(emu-identity identity.cpp "${CORE}/sha256.cpp")
target_include_directories(emu-identity PRIVATE "${CORE}")
target_link_libraries(emu-identity PRIVATE emu_snes)
set_target_properties(emu-identity PROPERTIES BUILD_RPATH "@loader_path")
