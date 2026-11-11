// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#pragma once
#include <array>
#include <atomic>
#include <algorithm>
#include <cstdint>
namespace emu {
// One simulation producer, one audio-device consumer. The callback never
// allocates, waits for a lock, or asks the UI thread to supply sound.
class AudioRing {
 static constexpr uint64_t capacity=16384;
 std::atomic<uint64_t> prebuffer{8010},highWater{12816};
 std::array<std::array<int16_t,2>,capacity> samples{};
 std::atomic<uint64_t> written{0},read{0};
 std::atomic<bool> adaptive{true};
 double fraction=0,rate=1;
 bool playing=false; // consumer only
public:
 void setWatcher(bool watcher){adaptive.store(watcher,std::memory_order_relaxed);prebuffer.store(watcher?8010:1068,std::memory_order_relaxed);highWater.store(watcher?12816:6408,std::memory_order_relaxed);}
 // Player video has its own clock, so this extra frame of audio reserve
 // does not delay steering or picture presentation.
 void setRollbackPlayer(){setWatcher(false);prebuffer.store(1602,std::memory_order_relaxed);}
 std::atomic<uint64_t> underruns{0},trims{0},dropped{0},rendered{0},maximumBuffered{0},minimumRatePPM{1000000},maximumRatePPM{1000000};
 uint64_t push(const int16_t *pcm,unsigned frames){
  auto w=written.load(std::memory_order_relaxed),r=read.load(std::memory_order_acquire);
  if(frames>capacity-(w-r)){dropped.fetch_add(frames,std::memory_order_relaxed);return w;}
  for(unsigned i=0;i<frames;i++)samples[(w+i)%capacity]={pcm[i*2],pcm[i*2+1]};
  written.store(w+frames,std::memory_order_release);return w+frames;
 }
 void pull(float *left,float *right,unsigned frames){
  auto r=read.load(std::memory_order_relaxed),w=written.load(std::memory_order_acquire),available=w-r;
  auto maximum=maximumBuffered.load(std::memory_order_relaxed);if(available>maximum)maximumBuffered.store(available,std::memory_order_relaxed);
  if(available>highWater.load(std::memory_order_relaxed)){r=w-prebuffer.load(std::memory_order_relaxed);available=w-r;trims.fetch_add(1,std::memory_order_relaxed);}
  auto target=prebuffer.load(std::memory_order_relaxed);
  if(!playing && available>=target){playing=true;fraction=0;rate=1;}
  // Device and emulation clocks are independent. A bounded, smoothed rate
  // correction keeps modest host slowdown from draining the watcher buffer.
  // This changes presentation only; deterministic emulation is untouched.
  if(playing && adaptive.load(std::memory_order_relaxed)){
   double desired=std::clamp(1.0+(double(available)-double(target))/(double(target)*20.0),0.99,1.01);
   rate+=(desired-rate)*0.05;
   uint64_t ppm=uint64_t(rate*1000000);
   if(ppm<minimumRatePPM.load(std::memory_order_relaxed))minimumRatePPM.store(ppm,std::memory_order_relaxed);
   if(ppm>maximumRatePPM.load(std::memory_order_relaxed))maximumRatePPM.store(ppm,std::memory_order_relaxed);
  }
  unsigned count=0;uint64_t consumed=0;
  if(playing)for(;count<frames;count++){
   if(consumed+1>=available)break;
   auto &a=samples[(r+consumed)%capacity];auto &b=samples[(r+consumed+1)%capacity];
   left[count]=float((a[0]+(b[0]-a[0])*fraction)/32768.0);right[count]=float((a[1]+(b[1]-a[1])*fraction)/32768.0);
   fraction+=rate;auto advance=uint64_t(fraction);fraction-=advance;consumed+=advance;
  }
  std::fill(left+count,left+frames,0.f);std::fill(right+count,right+frames,0.f);
  if(playing && count<frames){playing=false;fraction=0;underruns.fetch_add(1,std::memory_order_relaxed);}
  read.store(r+consumed,std::memory_order_release);rendered.fetch_add(count,std::memory_order_relaxed);

 }
 uint64_t position() const{return read.load(std::memory_order_acquire);}
};
}
