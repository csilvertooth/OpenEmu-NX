// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#pragma once
#include <cstdint>
#include <vector>
#include <stdexcept>
namespace emu {
using Bytes=std::vector<uint8_t>;
enum class Kind:uint16_t { Hello=1, Ready=2, Input=3, Hash=4, Done=5, Ack=6 };
inline void append(Bytes &b,uint64_t v,unsigned n) { for(unsigned i=0;i<n;++i)b.push_back(uint8_t(v>>(8*i))); }
struct Reader {
    const Bytes &b; size_t pos=0;
    uint64_t get(unsigned n) {
        if(n>8 || pos+n>b.size())throw std::runtime_error("truncated packet");
        uint64_t v=0; for(unsigned i=0;i<n;++i)v|=uint64_t(b[pos++])<<(8*i);return v;
    }
    void end() const { if(pos!=b.size())throw std::runtime_error("trailing packet bytes"); }
};
inline Bytes packet(Kind kind,uint64_t session,const Bytes &payload={}) {
    Bytes b{'E','X','N','P'};append(b,1,2);append(b,uint16_t(kind),2);append(b,session,8);
    b.insert(b.end(),payload.begin(),payload.end());return b;
}
inline Kind header(Reader &r,uint64_t session) {
    if(r.b.size()>512 || r.get(4)!=0x504e5845 || r.get(2)!=1)throw std::runtime_error("wire magic/version/size mismatch");
    auto kind=r.get(2);
    if(kind<1 || kind>6 || r.get(8)!=session)throw std::runtime_error("wrong session or packet type");
    return Kind(kind);
}
}
