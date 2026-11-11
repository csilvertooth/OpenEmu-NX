// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#pragma once
#include <atomic>
#include <algorithm>
#include <cstdint>
namespace emu {
// Audio callback publishes a bounded sample interval at its device host time.
// UI maps display target times onto it with at most two blocks of prediction.
// Prediction is bounded; underflow publications have zero slope. Atomic
// fields avoid a data race if a publication overlaps a read. The audio writer
// never waits; a contended UI read retains its previous position.
class PresentationClock {
 std::atomic<uint64_t> sequence{0};
 std::atomic<double> host{0},duration{0},start{0},end{0};
public:
 static_assert(std::atomic<double>::is_always_lock_free);
 void publish(double time,double seconds,uint64_t first,uint64_t last){
  sequence.fetch_add(1);host.store(time);duration.store(seconds);
  start.store(double(first));end.store(double(last));sequence.fetch_add(1);
 }
 bool advancing() const{return end.load()>start.load();}
 double blockDuration() const{return duration.load();}
 double hostLead(double time) const{return host.load()-time;}
 double position(double time,double fallback) const{
  for(int attempt=0;attempt<3;++attempt){
   auto before=sequence.load();if(!before || (before&1))continue;
   double t=host.load(),d=duration.load(),a=start.load(),b=end.load();
   if(sequence.load()!=before)continue;
   if(d<=0 || b<a)return fallback;
   // Engines may request the next block before its device presentation time.
   // The display also asks for its NEXT refresh, potentially beyond the latest
   // audio callback. Clamping at the block end recreates the buffer staircase.
   return std::max(0.0,a+(b-a)*std::clamp((time-t)/d,-2.0,3.0));
  }
  return fallback;
 }
};
// The ABI1 NTSC simulation runs one frame per 16639 us. Snes9x flushes
// variable audio chunks per frame; those chunk boundaries are not video times.
class FrameTimeline {
 unsigned previous=0;double sample=0;bool initialized=false;
public:
 double position(unsigned frame,double audioSample){
  if(!initialized || frame<=previous){sample=audioSample;initialized=true;}
  else{
   sample+=(frame-previous)*(32040.0*16639.0/1000000.0);
   double error=audioSample-sample;
   if(error>3204 || error< -3204)sample=audioSample;
   else sample+=std::clamp(error*0.002,-0.5,0.5);
  }
  previous=frame;return sample;
 }
};
// Device callbacks and sample-rate conversion introduce small timestamp noise.
// Follow their long-term phase without moving picture deadlines abruptly at a
// buffer boundary. This is UI-only; audio and emulation clocks are unchanged.
class VideoPhase {
 double previousTime=0,value=0;
 bool initialized=false;
public:
 double position(double time,double reference,bool advancing){
  if(!initialized || !advancing || time<=previousTime || time-previousTime>0.1){
   value=reference;initialized=true;
  }else{
   double step=(time-previousTime)*32040.0;
   double predicted=value+step,error=reference-predicted;
   if(error>3204 || error< -3204)value=reference;
   else value=predicted+std::clamp(error*0.02,-step*0.015,step*0.015);
  }
  previousTime=time;return value;
 }
};
// Player presentation is independent of audio buffering. A fixed 8 ms render
// margin absorbs small simulation scheduling jitter; packet arrival never
// moves deadlines. Rebase only after a real stall or a new timeline.
class PlayerTimeline {
 double origin=0;unsigned first=0,previous=0;
public:
 static constexpr double Interval=0.016639,Margin=0.008;
 double deadline(unsigned frame,double produced){
  if(!first || frame<=previous){first=frame;origin=produced+Margin;}
  double due=origin+(frame-first)*Interval;
  if(produced-due>4*Interval){first=frame;origin=produced+Margin;due=origin;}
  previous=frame;return due;
 }
};

}

