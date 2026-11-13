// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#include "rollback.h"
#include "multiplayer_save.h"
#include "emu_runtime.h"
#include <fstream>
#include <iostream>
#include <cstring>
#include <cstdlib>
using namespace emu;
void require(bool b,const char *m){if(!b)throw std::runtime_error(m);}
void check(int c){require(c==EMU_OK,"Runtime operation failed");}
template<class F> void rejects(F f){bool rejected=false;try{f();}catch(...){rejected=true;}require(rejected,"Invalid input accepted");}
int main(int argc,char **argv){try{
 require(argc==3,"Usage: emu-multitap-tests ROM PLAYERS");unsigned count=std::stoi(argv[2]);require(count>=3 && count<=5,"Invalid count");setenv("NX_NETPLAY_PLAYERS",argv[2],1);
 std::ifstream file(argv[1],std::ios::binary);Bytes rom((std::istreambuf_iterator<char>(file)),{});
 emu_runtime *core=nullptr;check(emu_create(EMU_RUNTIME_ABI,rom.data(),rom.size(),&core));uint32_t size;check(emu_state_size(core,&size));
 auto capture=[&](){Bytes b(size);check(emu_state_copy(core,b.data(),size));return b;};
 auto initial=capture();SaveInputs zero{};emu_frame out{};require(emu_step(core,0,0,&out)==EMU_ARGUMENT,"Two-pad API accepted multitap");require(emu_step_players(core,zero.data(),count-1,&out)==EMU_ARGUMENT,"Wrong topology accepted");
 auto damaged=initial;damaged[13]=2;require(emu_state_restore(core,damaged.data(),size)==EMU_STATE,"Snapshot topology not checked");
 constexpr unsigned frames=600;std::vector<SaveInputs> inputs(frames);std::map<unsigned,Bytes> reference;
 SaveJournal journal;journal.players=count;journal.identity.profile=emu_runtime_profile();journal.identity.rom=saveDigest(rom);journal.identity.initialState=saveDigest(initial);
 for(unsigned f=1;f<=frames;++f){for(unsigned p=0;p<count;++p)inputs[f-1][p]=(f%(17+p*2)==0)?uint16_t(1<<((f/17+p)%12)):0;check(emu_step_players(core,inputs[f-1].data(),count,&out));require(out.audio_frames>0,"Missing forward audio");journal.append(f,inputs[f-1]);if(f%60==0)reference[f]=capture();}
 journal.finalState=saveDigest(capture());auto encoded=journal.encode();auto decoded=SaveJournal::decode(encoded,journal.identity);require(decoded.players==count && decoded.encode()==encoded,"Multitap save did not round-trip");
 for(unsigned local=0;local<count;++local){check(emu_state_restore(core,initial.data(),size));unsigned emitted=0,confirmed=0;SaveJournal actual;actual.players=count;actual.identity=journal.identity;
  Rollback rb(count,local,capture,[&](const auto &s){check(emu_state_restore(core,s.data(),s.size()));},
   [&](unsigned f,const SaveInputs &pads,bool replay){require(pads[local]==inputs[f-1][local],"Local button changed during replay");check(emu_step_players(core,pads.data(),count,&out));if(!replay){require(out.audio_frames>0,"Forward audio absent");++emitted;}},
   [&](unsigned f,const Bytes &s){require(s==reference.at(f),"Multitap state diverged");++confirmed;},
   [&](unsigned f,const SaveInputs &pads){actual.append(f,pads);});
  rejects([&]{rb.putRemote(local,1,0);});rejects([&]{rb.putRemote(count,1,0);});
  struct Delivery{unsigned player,frame;};std::multimap<unsigned,Delivery> arrivals;
  for(unsigned f=1;f<=frames;++f)for(unsigned p=0;p<count;++p)if(p!=local)arrivals.emplace(f+1+(f+p*3)%9,Delivery{p,f});
  unsigned tick=0;while(rb.confirmed()<frames){require(++tick<frames+200,"Multiplayer rollback stalled");while(!arrivals.empty() && arrivals.begin()->first<=tick){auto d=arrivals.begin()->second;arrivals.erase(arrivals.begin());rb.putRemote(d.player,d.frame,inputs[d.frame-1][d.player]);}
   rb.reconcile();if(rb.ready() && rb.next()<=frames)rb.advance(inputs[rb.next()-1][local]);
  }
  require(emitted==frames && confirmed==frames/60,"Frame/audio duplicated or omitted");actual.finalState=saveDigest(capture());require(actual.encode()==encoded,"Confirmed save includes predicted inputs");
  std::cout<<"PASS "<<count<<" players, local slot "<<local+1<<", 600 frames, exact local inputs, "<<rb.rollbackCount<<" corrections, matching saves and 10 state checkpoints\n";
 }
 // Replay the decoded journal, including players 3–5, with no old save writes.
 check(emu_state_restore(core,initial.data(),size));for(const auto &run:decoded.runs())for(unsigned f=0;f<run.frames;++f){auto pads=run.inputs();check(emu_step_players(core,pads.data(),count,&out));}decoded.verifyFinal(saveDigest(capture()));
 emu_destroy(core);return 0;
}catch(const std::exception &e){std::cerr<<e.what()<<"\n";return 1;}}
