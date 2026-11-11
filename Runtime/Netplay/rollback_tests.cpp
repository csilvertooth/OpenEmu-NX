// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#include "rollback.h"
#include "emu_runtime.h"
#include <array>
#include <chrono>
#include <cstring>
#include <fstream>
#include <iostream>
using namespace emu;
static void require(bool value,const char *message){if(!value)throw std::runtime_error(message);}
static void check(int code){require(code==EMU_OK,"Runtime call failed");}
template<class F> void rejects(F fn){bool rejected=false;try{fn();}catch(const std::exception&){rejected=true;}require(rejected,"Invalid input accepted");}
static void unit(){
 uint64_t state=0;unsigned emitted=0,confirmed=0;std::vector<std::array<uint16_t,2>> applied,journal;
 Rollback r(0,[&](){Rollback::State b(8);memcpy(b.data(),&state,8);return b;},[&](const auto &b){memcpy(&state,b.data(),8);},
 [&](unsigned,uint16_t a,uint16_t b,bool replay){state=state*31+a+17*b;if(!replay){++emitted;applied.push_back({a,b});}},[&](unsigned n,const auto &){require(journal.size()==n,"Checkpoint preceded confirmed input journal");++confirmed;},
 [&](unsigned n,uint16_t a,uint16_t b){require(n==journal.size()+1,"Confirmed input duplicated or skipped");journal.push_back({a,b});});
 for(unsigned f=1;f<=12;f++)r.advance(f==2?4:0);
 require(!r.ready(),"Prediction horizon not bounded");rejects([&]{r.advance(0);});
 require(applied[1][0]==4 && applied[2][0]==0,"Local tap shifted or stretched");
 r.putRemote(3,0);r.putRemote(2,8);r.putRemote(1,0);r.putRemote(2,8);
 rejects([&]{r.putRemote(2,4);});rejects([&]{r.putRemote(0,0);});rejects([&]{r.putRemote(1000,0);});rejects([&]{r.putRemote(4,4096);});
 r.reconcile();require(r.confirmed()==3 && r.ready(),"Confirmation did not unblock");
 for(unsigned f=4;f<=12;f++)r.putRemote(f,0);r.reconcile();
 uint64_t expected=0;for(unsigned f=1;f<=12;f++)expected=expected*31+(f==2?4:0)+17*(f==2?8:0);
 require(state==expected && emitted==12 && r.rollbackCount>0,"Replay state or output count differs");
 require(journal.size()==12 && journal[1]==std::array<uint16_t,2>{4,8} && journal[2]==std::array<uint16_t,2>{0,0},"Journal retained predictions or altered a tap");
 for(unsigned f=13;f<=60;++f){r.putRemote(f,0);r.reconcile();r.advance(0);}
 require(journal.size()==60 && confirmed==1,"Confirmed journal did not reach checkpoint exactly once");
 RollbackAudio audio;int16_t block[256];std::fill(std::begin(block),std::end(block),1000);
 auto a=audio.forward(block,128);require(a.size()==256 && a[0]==1000,"Initial audio changed");
 audio.corrected();std::fill(std::begin(block),std::end(block),-1000);auto b=audio.forward(block,128);
 require(b.size()==256 && b[0]>900 && b[126]==-1000 && b.back()==-1000,"Correction bridge discontinuous");
 require(audio.forward(block,128)==std::vector<int16_t>(256,-1000),"Audio correction repeated");
 std::cout<<"PASS bounds, reordering, duplicate conflicts, exact local tap, replay output suppression, audio bridge\n";
}
int main(int argc,char **argv){try{
 unit();if(argc==1)return 0;require(argc==3,"Usage: emu-rollback-tests ROM TRACE");
 std::ifstream romFile(argv[1],std::ios::binary);std::vector<uint8_t> rom((std::istreambuf_iterator<char>(romFile)),{});
 std::ifstream traceFile(argv[2]);unsigned f,a,b;std::vector<std::array<uint16_t,2>> trace;
 while(traceFile>>f>>a>>b){require(f==trace.size()+1 && a<4096 && b<4096,"Invalid trace");trace.push_back({uint16_t(a),uint16_t(b)});}
 require(trace.size()>=9000,"Need racing trace through frame 9000");trace.resize(9000);
 emu_runtime *core=nullptr;check(emu_create(EMU_RUNTIME_ABI,rom.data(),uint32_t(rom.size()),&core));uint32_t size;check(emu_state_size(core,&size));
 auto capture=[&](){Rollback::State s(size);check(emu_state_copy(core,s.data(),size));return s;};
 auto initial=capture();std::map<unsigned,Rollback::State> reference;
 for(unsigned n=1;n<=trace.size();n++){emu_frame out{};check(emu_step(core,trace[n-1][0],trace[n-1][1],&out));if(n%60==0)reference[n]=capture();}
 for(unsigned local=0;local<2;local++){
  check(emu_state_restore(core,initial.data(),size));unsigned emitted=0,checks=0;uint64_t maxReplayUS=0;
  Rollback rb(local,capture,[&](const auto &s){check(emu_state_restore(core,s.data(),uint32_t(s.size())));},
   [&](unsigned n,uint16_t p1,uint16_t p2,bool replay){require((local?p2:p1)==trace[n-1][local],"Local input changed during replay");emu_frame out{};check(emu_step(core,p1,p2,&out));if(!replay)++emitted;},
   [&](unsigned n,const auto &s){require(s==reference.at(n),"Confirmed Snes9x state differs from reference");++checks;});
  std::multimap<unsigned,unsigned> delivery;
  for(unsigned n=1;n<=trace.size();n++)delivery.emplace(n+(n%17==0?10:1+n%7),n);
  unsigned tick=0;
  while(rb.confirmed()<trace.size()){
   require(++tick<10000,"Rollback did not drain");
   while(!delivery.empty() && delivery.begin()->first<=tick){auto n=delivery.begin()->second;delivery.erase(delivery.begin());rb.putRemote(n,trace[n-1][1-local]);if(n%13==0)rb.putRemote(n,trace[n-1][1-local]);}
   auto start=std::chrono::steady_clock::now();rb.reconcile();auto us=std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-start).count();maxReplayUS=std::max(maxReplayUS,uint64_t(us));
   if(rb.ready() && rb.next()<=trace.size())rb.advance(trace[rb.next()-1][local]);
  }
  require(emitted==trace.size() && checks==150 && capture()==reference.at(9000),"Final state or output count differs");
  std::cout<<"PASS real Snes9x player "<<local+1<<": 9000 frames, "<<checks<<" matching checkpoints, "<<rb.rollbackCount<<" rollbacks, max depth "<<rb.maximumDepth<<", max replay us "<<maxReplayUS<<", state bytes "<<size<<"\n";
 }
 emu_destroy(core);return 0;
}catch(const std::exception &e){std::cerr<<e.what()<<"\n";return 1;}}
