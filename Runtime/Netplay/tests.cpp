// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#include "lockstep.h"
#include "input_timing.h"
#include "wire.h"
#include <iostream>
#include <functional>
static void require(bool b){if(!b)throw std::runtime_error("test failed");}
static void rejects(std::function<void()> fn){bool threw=false;try{fn();}catch(const std::exception&){threw=true;}require(threw);}
int main() {
 using namespace emu;
 try {
    using namespace std::chrono;
    auto deadline=steady_clock::time_point{}+milliseconds(100);
    require(!inputSampleDue(0,1,deadline-microseconds(1),deadline));
    require(inputSampleDue(0,1,deadline,deadline));
    require(!inputSampleDue(1,1,deadline+milliseconds(20),deadline));
    require(hostStartOffset(94)==milliseconds(47));
    require(hostStartOffset(-1)==microseconds(0));
    require(hostStartOffset(2001)==microseconds(0));
    // Reordered release/press delivery and duplicate packets must preserve
    // a one-frame steering tap at every supported delay, on both peers.
    for(unsigned delay=1;delay<=12;++delay){
      Lockstep tap(delay);
      tap.put(0,delay+2,0);tap.put(0,delay+1,4);tap.put(0,delay+1,4);
      for(unsigned f=1;f<=delay+2;++f){
        if(f>delay)tap.put(1,f,0);
        require(tap.take()==std::array<uint16_t,2>{uint16_t(f==delay+1?4:0),0});
      }
    }
    rejects([]{Lockstep bad(0);});Lockstep q(3);
    for(int i=1;i<=3;++i){require(q.next()==unsigned(i));require(q.take()==std::array<uint16_t,2>{0,0});}
    require(!q.ready());rejects([&]{q.take();});require(q.next()==4);
    q.put(1,5,32);q.put(0,4,16);require(!q.ready());q.put(1,4,8);q.put(1,4,8);
    rejects([&]{q.put(1,4,9);});require(q.take()==std::array<uint16_t,2>{16,8});
    q.put(0,5,64);require(q.take()==std::array<uint16_t,2>{64,32});
    rejects([&]{q.put(0,127,0);});rejects([&]{q.put(2,6,0);});rejects([&]{q.put(0,6,4096);});
    for(unsigned f=6;f<=250;++f){q.put(1,f,uint16_t(f));q.put(0,f,0);q.take();}
    rejects([&]{q.put(0,4,16);});
    auto b=packet(Kind::Ready,42);Reader r{b};require(header(r,42)==Kind::Ready);r.end();
    for(size_t n=0;n<b.size();++n){Bytes cut(b.begin(),b.begin()+n);rejects([&]{Reader c{cut};header(c,42);});}
    rejects([&]{Reader c{b};header(c,43);});b.push_back(0);rejects([&]{Reader c{b};header(c,42);c.end();});
    b[4]=2;rejects([&]{Reader c{b};header(c,42);});
    std::cout<<"PASS scheduler stall/reorder/duplicate/bounds/history and wire validation\n";
 }catch(const std::exception &e){std::cerr<<e.what()<<"\n";return 1;}
}
