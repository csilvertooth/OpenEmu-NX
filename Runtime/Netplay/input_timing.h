// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#pragma once
#include <chrono>
namespace emu {
inline std::chrono::microseconds hostStartOffset(int rttMS) {
    // Invalid/stale connection statistics must not postpone startup indefinitely.
    return std::chrono::microseconds(rttMS >= 0 && rttMS <= 2000 ? rttMS * 500 : 0);
}
template<class Time> bool inputSampleDue(unsigned sampled, unsigned frame, Time now, Time deadline) {
    // Capture at the frame deadline, not immediately after the preceding frame.
    // A missing remote input must not prevent sending our next local input.
    return sampled != frame && now >= deadline;
}
}
