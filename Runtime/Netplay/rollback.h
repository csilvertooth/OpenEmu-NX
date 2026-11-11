// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#pragma once
#include <algorithm>
#include <cstdint>
#include <functional>
#include <map>
#include <stdexcept>
#include <vector>
namespace emu {
// Single simulation owner. Local inputs are immutable. Only remote input is
// predicted. Snapshots never cross the network and replay has no presentation.
class Rollback {
public:
 using State=std::vector<uint8_t>;
 using Capture=std::function<State()>;
 using Restore=std::function<void(const State&)>;
 using Step=std::function<void(unsigned,uint16_t,uint16_t,bool)>;
 using Confirm=std::function<void(unsigned,const State&)>;
 using ConfirmedInput=std::function<void(unsigned,uint16_t,uint16_t)>;
 static constexpr unsigned Horizon=12,Window=120;
 Rollback(unsigned localPlayer,Capture capture,Restore restore,Step step,Confirm confirm,ConfirmedInput confirmedInput={})
  :localPlayer_(localPlayer),capture_(capture),restore_(restore),step_(step),confirm_(confirm),confirmedInput_(confirmedInput){
  if(localPlayer>1)throw std::runtime_error("Invalid local player");
 }
 unsigned next()const{return next_;}
 unsigned confirmed()const{return confirmed_;}
 bool ready()const{return next_-confirmed_<=Horizon;}
 unsigned rollbackCount=0,replayedFrames=0,maximumDepth=0;
 void putRemote(unsigned frame,uint16_t mask){
  if(!frame || mask>4095 || frame>next_+Window || (frame<confirmed_ && confirmed_-frame>Window))
   throw std::runtime_error("Remote input outside rollback window");
  auto found=remote_.find(frame);
  if(found!=remote_.end()){if(found->second!=mask)throw std::runtime_error("Conflicting remote input");return;}
  if(frame<=confirmed_)throw std::runtime_error("Missing confirmed input history");
  remote_[frame]=mask;
  // Recompute every affected prediction: an early actual input can alter the
  // prediction for later frames even when its own prediction happened to match.
  for(auto it=frames_.lower_bound(frame);it!=frames_.end();++it)
   if(it->second.remote!=predict(it->first)){dirty_=dirty_?std::min(dirty_,it->first):it->first;break;}
 }
 void reconcile(){
  if(dirty_){
   unsigned start=dirty_;dirty_=0;restore_(frames_.at(start).before);
   ++rollbackCount;maximumDepth=std::max(maximumDepth,next_-start);
   for(unsigned f=start;f<next_;++f){auto &record=frames_.at(f);record.before=capture();record.remote=predict(f);run(f,record,true);++replayedFrames;}
  }
  confirm();
 }
 void advance(uint16_t local){
  if(local>4095 || !ready() || dirty_)throw std::runtime_error("Rollback cannot advance");
  Record record;record.local=local;record.remote=predict(next_);record.before=capture();
  run(next_,record,false);frames_.emplace(next_,std::move(record));++next_;confirm();
 }
private:
 struct Record{uint16_t local=0,remote=0;State before,checkpoint;};
 unsigned localPlayer_,next_=1,confirmed_=0,dirty_=0;
 std::map<unsigned,uint16_t> remote_;
 std::map<unsigned,Record> frames_;
 Capture capture_;Restore restore_;Step step_;Confirm confirm_;ConfirmedInput confirmedInput_;
 State capture(){auto s=capture_();if(s.empty() || s.size()>8*1024*1024)throw std::runtime_error("Invalid rollback snapshot size");return s;}
 uint16_t predict(unsigned f)const{auto it=remote_.upper_bound(f);return it==remote_.begin()?0:std::prev(it)->second;}
 void run(unsigned f,Record &r,bool replay){step_(f,localPlayer_?r.remote:r.local,localPlayer_?r.local:r.remote,replay);if(f%60==0)r.checkpoint=capture();}
 void confirm(){
  while(confirmed_+1<next_ && remote_.count(confirmed_+1)){
   auto it=frames_.find(++confirmed_);if(it==frames_.end())throw std::runtime_error("Missing rollback frame");
   if(confirmedInput_){auto &r=it->second;confirmedInput_(confirmed_,localPlayer_?r.remote:r.local,localPlayer_?r.local:r.remote);}
   if(confirmed_%60==0)confirm_(confirmed_,it->second.checkpoint);
   frames_.erase(it);
  }
  while(!remote_.empty() && remote_.begin()->first+Window<confirmed_)remote_.erase(remote_.begin());
 }
};
// Emit audio once per new frame. Replayed audio is discarded. If the corrected
// timeline differs, bridge 2 ms into the next new block to avoid a hard click.
class RollbackAudio {
 int16_t previous_[2]={0,0};bool emitted_=false,corrected_=false;
public:
 void corrected(){corrected_=true;}
 std::vector<int16_t> forward(const int16_t *pcm,unsigned frames){
  std::vector<int16_t> result;if(!frames)return result;
  result.assign(pcm,pcm+frames*2);
  if(corrected_ && emitted_){unsigned count=std::min(frames,64u);for(unsigned i=0;i<count;++i)for(unsigned c=0;c<2;++c)
   result[i*2+c]=int16_t((int32_t(previous_[c])*(count-i-1)+int32_t(result[i*2+c])*(i+1))/int32_t(count));}
  previous_[0]=result[result.size()-2];previous_[1]=result.back();emitted_=true;corrected_=false;return result;
 }
};
}
