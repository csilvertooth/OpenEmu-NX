// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#pragma once
#include <algorithm>
#include <array>
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
 using Inputs=std::array<uint16_t,5>;
 using State=std::vector<uint8_t>;
 using Capture=std::function<State()>;
 using Restore=std::function<void(const State&)>;
 using Step=std::function<void(unsigned,uint16_t,uint16_t,bool)>;
 using Confirm=std::function<void(unsigned,const State&)>;
 using ConfirmedInput=std::function<void(unsigned,uint16_t,uint16_t)>;
 static constexpr unsigned Horizon=12,Window=120;
 using MultiStep=std::function<void(unsigned,const Inputs&,bool)>;
 using MultiInput=std::function<void(unsigned,const Inputs&)>;
 Rollback(unsigned localPlayer,Capture capture,Restore restore,Step step,Confirm confirm,ConfirmedInput input={})
  :Rollback(2,localPlayer,capture,restore,[step](unsigned f,const Inputs &p,bool replay){step(f,p[0],p[1],replay);},confirm,
   [input](unsigned f,const Inputs &p){if(input)input(f,p[0],p[1]);}){}
 Rollback(unsigned players,unsigned localPlayer,Capture capture,Restore restore,MultiStep step,Confirm confirm,MultiInput input={})
  :players_(players),localPlayer_(localPlayer),capture_(capture),restore_(restore),step_(step),confirm_(confirm),confirmedInput_(input){
  if(players<2 || players>5 || localPlayer>=players)throw std::runtime_error("Invalid player topology");
 }
 unsigned next()const{return next_;}
 unsigned confirmed()const{return confirmed_;}
 bool ready()const{return next_-confirmed_<=Horizon;}
 unsigned rollbackCount=0,replayedFrames=0,maximumDepth=0;
 void putRemote(unsigned frame,uint16_t mask){putRemote(1-localPlayer_,frame,mask);}
 void putRemote(unsigned player,unsigned frame,uint16_t mask){
  if(player>=players_ || player==localPlayer_)throw std::runtime_error("Invalid remote player");
  auto &remote=remote_[player];
  if(!frame || mask>4095 || frame>next_+Window || (frame<confirmed_ && confirmed_-frame>Window))
   throw std::runtime_error("Remote input outside rollback window");
  auto found=remote.find(frame);
  if(found!=remote.end()){if(found->second!=mask)throw std::runtime_error("Conflicting remote input");return;}
  if(frame<=confirmed_)throw std::runtime_error("Missing confirmed input history");
  remote[frame]=mask;
  // Recompute every affected prediction: an early actual input can alter the
  // prediction for later frames even when its own prediction happened to match.
  for(auto it=frames_.lower_bound(frame);it!=frames_.end();++it)
   if(it->second.inputs[player]!=predict(player,it->first)){dirty_=dirty_?std::min(dirty_,it->first):it->first;break;}
 }
 void reconcile(){
  if(dirty_){
   unsigned start=dirty_;dirty_=0;restore_(frames_.at(start).before);
   ++rollbackCount;maximumDepth=std::max(maximumDepth,next_-start);
   for(unsigned f=start;f<next_;++f){auto &record=frames_.at(f);record.before=capture();predictInputs(f,record);run(f,record,true);++replayedFrames;}
  }
  confirm();
 }
 void advance(uint16_t local){
  if(local>4095 || !ready() || dirty_)throw std::runtime_error("Rollback cannot advance");
  Record record;record.inputs[localPlayer_]=local;predictInputs(next_,record);record.before=capture();
  run(next_,record,false);frames_.emplace(next_,std::move(record));++next_;confirm();
 }
private:
 struct Record{Inputs inputs{};State before,checkpoint;};
 unsigned players_,localPlayer_,next_=1,confirmed_=0,dirty_=0;
 std::array<std::map<unsigned,uint16_t>,5> remote_;
 std::map<unsigned,Record> frames_;
 Capture capture_;Restore restore_;MultiStep step_;Confirm confirm_;MultiInput confirmedInput_;
 State capture(){auto s=capture_();if(s.empty() || s.size()>8*1024*1024)throw std::runtime_error("Invalid rollback snapshot size");return s;}
 uint16_t predict(unsigned player,unsigned f)const{auto &remote=remote_[player];auto it=remote.upper_bound(f);return it==remote.begin()?0:std::prev(it)->second;}
 void predictInputs(unsigned f,Record &r){for(unsigned p=0;p<players_;++p)if(p!=localPlayer_)r.inputs[p]=predict(p,f);}
 bool actual(unsigned f)const{for(unsigned p=0;p<players_;++p)if(p!=localPlayer_ && !remote_[p].count(f))return false;return true;}
 void run(unsigned f,Record &r,bool replay){step_(f,r.inputs,replay);if(f%60==0)r.checkpoint=capture();}
 void confirm(){
  while(confirmed_+1<next_ && actual(confirmed_+1)){
   auto it=frames_.find(++confirmed_);if(it==frames_.end())throw std::runtime_error("Missing rollback frame");
   if(confirmedInput_){auto &r=it->second;confirmedInput_(confirmed_,r.inputs);}
   if(confirmed_%60==0)confirm_(confirmed_,it->second.checkpoint);
   frames_.erase(it);
  }
  for(auto &remote:remote_)while(!remote.empty() && remote.begin()->first+Window<confirmed_)remote.erase(remote.begin());
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
