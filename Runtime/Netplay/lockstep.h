// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#pragma once
#include <array>
#include <cstdint>
#include <map>
#include <stdexcept>

namespace emu {
// One owner thread. Frames 1..delay are agreed neutral bootstrap; input sampled
// before executing frame n belongs to n+delay. Never predicts or skips a frame.
class Lockstep {
public:
    static constexpr uint32_t Window = 120, History = 120;
    explicit Lockstep(uint32_t delay) : delay_(delay) {
        if (delay < 1 || delay > 12) throw std::runtime_error("delay must be 1..12");
        for (uint32_t f=1; f<=delay; ++f) { put(0,f,0); put(1,f,0); }
    }
    uint32_t next() const { return next_; }
    uint32_t sampleFrame() const { return next_ + delay_; }
    void put(unsigned player, uint32_t frame, uint16_t mask) {
        if (player>1 || !frame || mask>4095 || frame>next_+Window)
            throw std::runtime_error("invalid or out-of-window input");
        if (frame < next_ && next_-frame > History)
            throw std::runtime_error("input older than retained history");
        auto &slot = inputs_[player];
        auto found=slot.find(frame);
        if (found!=slot.end()) {
            if (found->second!=mask) throw std::runtime_error("conflicting duplicate input");
            return;
        }
        if (frame<next_) throw std::runtime_error("missing input history");
        slot.emplace(frame,mask);
    }
    bool ready() const { return inputs_[0].count(next_) && inputs_[1].count(next_); }
    std::array<uint16_t,2> take() {
        if (!ready()) throw std::runtime_error("missing input: cannot advance");
        std::array<uint16_t,2> pair{inputs_[0].at(next_),inputs_[1].at(next_)};
        ++next_;
        for (auto &slot:inputs_)
            while (!slot.empty() && slot.begin()->first+History<next_) slot.erase(slot.begin());
        return pair;
    }
private:
    uint32_t delay_, next_=1;
    std::map<uint32_t,uint16_t> inputs_[2];
};
}
