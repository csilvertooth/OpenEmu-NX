// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#include "multiplayer_save.h"
#include "emu_runtime.h"
#include "rollback.h"
#include <chrono>
#include <dlfcn.h>
#include <filesystem>
#include <cstdlib>
#include <iostream>
#include <fstream>
#include <unistd.h>
using namespace emu;
static void require(bool value,const char *why){if(!value)throw std::runtime_error(why);}
template<class Fn>static void rejects(Fn fn){bool threw=false;try{fn();}catch(const std::exception&){threw=true;}require(threw,"Invalid save accepted");}
static void resign(Bytes &b){b.resize(b.size()-32);auto d=saveDigest(b);b.insert(b.end(),d.begin(),d.end());}
static void realCore(const char *romPath,const char *tracePath){
 auto read=[](const char *path){std::ifstream f(path,std::ios::binary);if(!f)throw std::runtime_error("Cannot read test data");return Bytes((std::istreambuf_iterator<char>(f)),{});};
 auto rom=read(romPath);std::ifstream input(tracePath);unsigned n,a,b;std::vector<std::array<uint16_t,2>> trace;
 while(input>>n>>a>>b){require(n==trace.size()+1 && a<4096 && b<4096,"Invalid replay trace");trace.push_back({uint16_t(a),uint16_t(b)});}
 require(trace.size()>=9000,"Real save test needs racing trace through frame 9000");
 emu_runtime *core=nullptr;auto check=[](int code){require(code==EMU_OK,"Runtime operation failed");};
 check(emu_create(EMU_RUNTIME_ABI,rom.data(),uint32_t(rom.size()),&core));
 try{
  uint32_t size;check(emu_state_size(core,&size));auto snapshot=[&](){Bytes bytes(size);check(emu_state_copy(core,bytes.data(),size));return bytes;};
  auto initial=snapshot();Dl_info info{};require(dladdr((void*)&emu_create,&info)!=0,"Runtime identity unavailable");
  SaveJournal journal;journal.identity={emu_runtime_profile(),saveDigest(rom),saveDigest(read(info.dli_fname)),saveDigest(initial)};SaveJournal saved;
  for(unsigned f=1;f<=9000;++f){emu_frame out{};check(emu_step(core,trace[f-1][0],trace[f-1][1],&out));journal.append(f,trace[f-1][0],trace[f-1][1]);
   if(f==8400){saved=journal;saved.finalState=saveDigest(snapshot());}}
  auto final=snapshot();auto bytes=saved.encode();SaveTransfer transfer;transfer.begin(bytes.size(),saveDigest(bytes));
  for(size_t offset=0;offset<bytes.size();offset+=SaveTransfer::chunkSize()){size_t length=std::min(SaveTransfer::chunkSize(),bytes.size()-offset);transfer.put(offset,Bytes(bytes.begin()+offset,bytes.begin()+offset+length));}
  auto loaded=SaveJournal::decode(transfer.finish(),journal.identity);
  // Only this test's own trusted local initial snapshot is restored. Received
  // save bytes go exclusively through replayed validated joypad inputs.
  check(emu_state_restore(core,initial.data(),uint32_t(initial.size())));auto started=std::chrono::steady_clock::now();
  loaded.replay([&](unsigned,uint16_t p1,uint16_t p2){emu_frame out{};check(emu_step(core,p1,p2,&out));},[](unsigned,unsigned){return true;});
  loaded.verifyFinal(saveDigest(snapshot()));auto replayMS=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-started).count();
  for(unsigned f=8401;f<=9000;++f){emu_frame out{};check(emu_step(core,trace[f-1][0],trace[f-1][1],&out));loaded.append(f,trace[f-1][0],trace[f-1][1]);}
  require(snapshot()==final,"Continued saved game diverged from uninterrupted race");
  std::cout<<"PASS real Snes9x save at 8400, transferred replay and continuation to 9000; "<<bytes.size()<<" save bytes, "<<replayMS<<" replay ms\n";
 }catch(...){emu_destroy(core);throw;}emu_destroy(core);
}
int main(int argc,char **argv){try{
 SaveIdentity id{"snes9x-test",saveDigest(Bytes{1}),saveDigest(Bytes{2}),saveDigest(Bytes{3})};
 SaveJournal journal;journal.identity=id;
 for(unsigned f=1;f<=240;++f)journal.append(f,f==61?4:0,f>=120&&f<125?32:0);
 journal.finalState=saveDigest(Bytes{4});auto bytes=journal.encode();auto decoded=SaveJournal::decode(bytes,id);
 require(decoded.frames()==240 && decoded.runs().size()==5,"RLE round trip differs");
 unsigned visited=0;decoded.replay([&](unsigned f,uint16_t p1,uint16_t p2){require(f==++visited && p1==(f==61?4:0) && p2==(f>=120&&f<125?32:0),"Saved input tap changed");},[](unsigned,unsigned){return true;});
 require(visited==240,"Replay omitted frames");decoded.verifyFinal(journal.finalState);
 rejects([&]{decoded.verifyFinal(saveDigest(Bytes{5}));});
 rejects([&]{decoded.replay([](unsigned,uint16_t,uint16_t){},[](unsigned f,unsigned){return f<60;});});
 SaveIdentity wrong=id;wrong.runtime=saveDigest(Bytes{9});rejects([&]{SaveJournal::decode(bytes,wrong);});
 wrong=id;wrong.rom=saveDigest(Bytes{9});rejects([&]{SaveJournal::decode(bytes,wrong);});
 wrong=id;wrong.initialState=saveDigest(Bytes{9});rejects([&]{SaveJournal::decode(bytes,wrong);});
 for(size_t size:{size_t(0),size_t(8),size_t(152),bytes.size()-1}){Bytes cut(bytes.begin(),bytes.begin()+size);rejects([&]{SaveJournal::decode(cut,id);});}
 auto corrupted=bytes;corrupted.back()^=1;rejects([&]{SaveJournal::decode(corrupted,id);});
 corrupted=bytes;corrupted[8]=2;resign(corrupted);rejects([&]{SaveJournal::decode(corrupted,id);});
 corrupted=bytes;corrupted[12]=0;corrupted[13]=0;resign(corrupted);rejects([&]{SaveJournal::decode(corrupted,id);});
 corrupted=bytes;size_t firstRun=24+128+id.profile.size();corrupted[firstRun]=0;corrupted[firstRun+1]=0;corrupted[firstRun+2]=0;corrupted[firstRun+3]=0;resign(corrupted);rejects([&]{SaveJournal::decode(corrupted,id);});
 corrupted=bytes;corrupted[firstRun+5]=0x10;resign(corrupted);rejects([&]{SaveJournal::decode(corrupted,id);});
 rejects([&]{journal.append(242,0,0);});rejects([&]{journal.append(241,4096,0);});
 SaveTransfer transfer;transfer.begin(bytes.size(),saveDigest(bytes));size_t half=bytes.size()/2;
 Bytes first(bytes.begin(),bytes.begin()+half),last(bytes.begin()+half,bytes.end());
 rejects([&]{transfer.put(half,last);});transfer.put(0,first);transfer.put(0,first);
 rejects([&]{transfer.finish();});auto changed=first;changed[0]^=1;rejects([&]{transfer.put(0,changed);});
 transfer.put(half,last);require(transfer.finish()==bytes,"Chunk transfer differs");
 rejects([&]{transfer.begin(10,{});});SaveTransfer oversized;rejects([&]{oversized.begin(SaveJournal::MaxBytes+1,{});});
 char directory[]="/tmp/emu-save-test-XXXXXX";require(mkdtemp(directory)!=nullptr,"Cannot create scratch directory");
 std::filesystem::path dir(directory),file=dir/"continuation.emuxsave";
 try{
  writeMultiplayerSave(file.string(),bytes);require(readMultiplayerSave(file.string())==bytes,"Stored save differs");
  auto extended=journal;for(unsigned f=241;f<=300;++f)extended.append(f,0,0);
  {SaveWriter writer(file.string());writer.submit(journal);writer.submit(extended);}
  require(SaveJournal::decode(readMultiplayerSave(file.string()),id).frames()==300,"Writer did not flush latest confirmed save");
  auto link=dir/"link";std::filesystem::create_symlink(file,link);rejects([&]{readMultiplayerSave(link.string());});
  require(std::distance(std::filesystem::directory_iterator(dir),std::filesystem::directory_iterator{})==2,"Temporary save file leaked");
 }catch(...){std::filesystem::remove_all(dir);throw;}
 std::filesystem::remove_all(dir);
 // Interrupt after simulation has advanced past confirmed input. Reconstruct
 // only the confirmed tail from a trusted checkpoint, including a brief tap.
 SaveJournal interrupted;interrupted.identity=id;unsigned toy=0,checkpointValue=0,checkpointFrame=0;
 auto capture=[&](){Bytes b;append(b,toy,4);return b;};
 Rollback rollback(0,capture,[&](const Bytes &b){Reader r{b};toy=unsigned(r.get(4));},
  [&](unsigned,uint16_t p1,uint16_t p2,bool){toy=toy*33+p1*7+p2;},
  [&](unsigned f,const Bytes &b){Reader r{b};checkpointValue=unsigned(r.get(4));checkpointFrame=f;},
  [&](unsigned f,uint16_t p1,uint16_t p2){interrupted.append(f,p1,p2);});
 unsigned expected=0;
 for(unsigned f=1;f<=73;++f){uint16_t p1=f==65?4:0,p2=f==64?16:0;
  if(f<=67){rollback.putRemote(f,p2);expected=expected*33+p1*7+p2;}
  rollback.advance(p1);
 }
 require(rollback.confirmed()==67 && checkpointFrame==60,"Partial confirmation fixture failed");
 toy=checkpointValue;unsigned tail=0;
 interrupted.replayConfirmedTail(checkpointFrame,[&](unsigned,uint16_t p1,uint16_t p2){toy=toy*33+p1*7+p2;++tail;});
 require(tail==7 && toy==expected && interrupted.frames()==67,"Interrupted save included prediction or lost confirmed taps");
 interrupted.finalState=saveDigest(capture());
 auto recovered=SaveJournal::decode(interrupted.encode(),id);toy=0;
 recovered.replay([&](unsigned,uint16_t p1,uint16_t p2){toy=toy*33+p1*7+p2;},[](unsigned,unsigned){return true;});
 recovered.verifyFinal(saveDigest(capture()));
 rejects([&]{interrupted.replayConfirmedTail(68,[](unsigned,uint16_t,uint16_t){});});
 rejects([&]{interrupted.replayConfirmedTail(0,[](unsigned,uint16_t,uint16_t){});});
 if(argc!=1){require(argc==3,"Usage: emu-save-tests [ROM TRACE]");realCore(argv[1],argv[2]);}
 std::cout<<"PASS save identity/integrity/bounds, exact input replay, cancellation, chunk transfer and atomic background storage\n";
 return 0;
}catch(const std::exception &e){std::cerr<<e.what()<<"\n";return 1;}}
