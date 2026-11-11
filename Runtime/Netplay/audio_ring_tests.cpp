// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#include "audio_ring.h"
#include "presentation_clock.h"
#include <cmath>
#include <iostream>
#include <vector>
#include <deque>
#include <stdexcept>
using namespace emu;
static void require(bool b){if(!b)throw std::runtime_error("audio ring test failed");}
int main(){
 // +/-3 ms producer jitter near vsync must not alternate skipped/repeated
 // player pictures. This models the observed unsynchronized latest-frame race.
 PlayerTimeline player;std::deque<std::pair<unsigned,double>> pictures;
 unsigned produced=0,shown=0,repeats=0,skips=0;
 for(unsigned tick=0;tick<600;tick++){
  double target=tick/60.0;
  while(true){unsigned f=produced+1;double arrival=f*PlayerTimeline::Interval+(f%2?0.003:-0.003);
   if(arrival>target)break;pictures.emplace_back(f,player.deadline(f,arrival));produced=f;}
  unsigned selected=0;while(!pictures.empty() && pictures.front().second<=target){if(selected)++skips;selected=pictures.front().first;pictures.pop_front();}
  if(selected)shown=selected;else if(shown)++repeats;
 }
 require(repeats<=2 && skips<=2 && shown>590);
 require(player.deadline(1000,100)>100);
 AudioRing playerAudio;playerAudio.setRollbackPlayer();std::vector<int16_t> playerBlock(534*2,8192);float pl[256],pr[256];
 double playerPacket=0;
 for(unsigned cb=0;cb<2500;cb++){
  double now=cb*256.0/32040;
  // One delayed simulation burst, covered by the independent audio reserve.
  if(!(now>=5 && now<5.020))while(playerPacket<=now){playerAudio.push(playerBlock.data(),534);playerPacket+=0.016639;}
  playerAudio.pull(pl,pr,256);
 }
 require(playerAudio.underruns==0 && playerAudio.trims==0 && playerAudio.dropped==0);
 PresentationClock clock;
 require(clock.position(1,42)==42);
 clock.publish(10,0.008,1000,1256);
 require(clock.position(11,0)==1768);
 require(std::abs(clock.position(10.012,0)-1384)<1e-6);
 require(std::abs(clock.position(9.996,0)-872)<1e-6);
 require(std::abs(clock.position(10.004,0)-1128)<1e-6);
 // Verify continuity over differently sized callbacks and a resampled block.
 clock.publish(10.008,0.016,1256,1770);
 require(clock.position(10.008,0)==1256);
 require(std::abs(clock.position(10.016,0)-1513)<1e-6);
 // Prebuffering/underflow holds video; trimming starts a new timeline.
 clock.publish(10.024,0.008,1770,1770);
 require(clock.position(10.028,0)==1770);
 clock.publish(11,0.008,4000,4000);
 require(clock.position(11.004,0)==4000);

 // The measured SNES chunk pattern must not become video deadline jitter.
 FrameTimeline timeline;double audioSample=0,deadline=timeline.position(1,0);
 for(unsigned frame=2;frame<=1800;++frame){
  audioSample+=(frame%5==0?512:538);
  double next=timeline.position(frame,audioSample);
  require(next-deadline>532.6 && next-deadline<533.7);deadline=next;
 }
 // Missing video frames retain their media-time spacing, rather than bunching.
 double next=timeline.position(1803,audioSample+3*533.12);
 require(next-deadline>1598 && next-deadline<1601);
 // Video must not inherit a device timestamp's alternating +/-2 ms noise.
 VideoPhase phase;double prior=phase.position(20,10000,true);
 for(int i=1;i<=600;i++){
  double reference=10000+i*534.0+(i%2?64:-64);
  double current=phase.position(20+i/60.0,reference,true);
  require(current>prior && std::abs((current-prior)-534)<3);
  require(std::abs(current-(10000+i*534.0))<5);prior=current;
 }
 require(phase.position(31,prior,false)==prior);
 require(phase.position(32,500000,true)==500000);
 // Independently paced 60 Hz network producer and 256-sample device callback.
 // Device presentation latency never feeds back into queue occupancy.
 AudioRing ring;std::vector<int16_t> pcm(534*2,8192);float l[256],r[256];
 double nextPacket=0;for(unsigned callback=0;callback<2500;callback++){
  double now=callback*256.0/32040;
  while(nextPacket<=now){ring.push(pcm.data(),534);nextPacket+=1.0/60;}
  ring.pull(l,r,256);
  for(unsigned i=0;i<256;i++)require(l[i]==r[i] && (l[i]==0 || l[i]==.25f));
 }
 require(ring.underruns==0 && ring.trims==0 && ring.dropped==0 && ring.rendered>625000);
 pcm.resize(1068*2,8192);
 // Deliberate starvation is counted once and requires prebuffering again.
 for(unsigned i=0;i<50;i++)ring.pull(l,r,256);require(ring.underruns==1);
 auto before=ring.rendered.load();ring.push(pcm.data(),1068);ring.pull(l,r,256);require(ring.rendered==before);
 for(unsigned i=0;i<7;i++)ring.push(pcm.data(),1068);ring.pull(l,r,256);require(ring.rendered==before+256);
 // A stalled device skips stale data once, preserving bounded latency.
 for(unsigned i=0;i<5;i++)ring.push(pcm.data(),1068);ring.pull(l,r,256);require(ring.trims==1);
 // A slightly slower host clock plus a 100 ms network/CPU stall must not
 // gradually drain the device buffer. Run two simulated minutes.
 AudioRing drift;std::vector<int16_t> block(534*2,8192);double packet=0;
 for(unsigned cb=0;cb<15000;cb++){
  double now=cb*256.0/32040;
  if(!(now>=50 && now<50.1))while(packet<=now){drift.push(block.data(),534);packet+=1.0/59.8;}
  drift.pull(l,r,256);
 }
 require(drift.underruns==0 && drift.trims==0 && drift.dropped==0 && drift.minimumRatePPM>=990000 && drift.minimumRatePPM<999000);
 std::cout<<"PASS interpolated video clock, continuous PCM, startup, starvation recovery and bounded backlog\n";
}
