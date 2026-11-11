// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#pragma once
#include "wire.h"
#include <openssl/sha.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <functional>
#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>
#include <string>
#include <utility>

namespace emu {
using SaveDigest=std::array<uint8_t,32>;
inline SaveDigest saveDigest(const Bytes &bytes){SaveDigest d{};SHA256(bytes.data(),bytes.size(),d.data());return d;}
inline SaveDigest saveDigestFromHex(const std::string &text){
 if(text.size()!=64)throw std::runtime_error("Invalid saved-game identity hash");
 SaveDigest result{};auto digit=[](char c)->unsigned{if(c>='0'&&c<='9')return c-'0';if(c>='a'&&c<='f')return c-'a'+10;throw std::runtime_error("Invalid saved-game identity hash");};
 for(unsigned i=0;i<32;++i)result[i]=uint8_t((digit(text[i*2])<<4)|digit(text[i*2+1]));return result;
}
inline std::string saveDigestHex(const SaveDigest &digest){static constexpr char hex[]="0123456789abcdef";std::string s;for(uint8_t c:digest){s+=hex[c>>4];s+=hex[c&15];}return s;}
struct SaveIdentity {
 std::string profile;
 SaveDigest rom{},runtime{},initialState{};
 bool operator==(const SaveIdentity &b)const{return profile==b.profile && rom==b.rom && runtime==b.runtime && initialState==b.initialState;}
};
struct SaveRun {uint32_t frames;uint16_t player1,player2;};
// An input journal, never a serialized emulator object. A received journal is
// replayed through the bounded joypad ABI after verifying identity/integrity.
// These are parser/resource bounds, not lobby/account quotas. RLE handles long
// unchanged input periods; callbacks allow cancellation during lengthy replay.
class SaveJournal {
public:
 static constexpr uint32_t MaxFrames=10000000,MaxRuns=1000000;
 static constexpr size_t MaxBytes=8u*MaxRuns+512u;
 SaveIdentity identity;
 SaveDigest finalState{};
 uint32_t frames()const{return frames_;}
 const std::vector<SaveRun> &runs()const{return runs_;}
 void append(uint32_t frame,uint16_t p1,uint16_t p2){
  if(frame!=frames_+1 || frame>MaxFrames || (p1|p2)>4095)throw std::runtime_error("Invalid confirmed saved-game input");
  if(!runs_.empty() && runs_.back().player1==p1 && runs_.back().player2==p2)++runs_.back().frames;
  else{if(runs_.size()>=MaxRuns)throw std::runtime_error("Saved-game input history is full");runs_.push_back({1,p1,p2});}
  frames_=frame;
 }
 template<class Step,class Progress> void replay(Step step,Progress progress)const{
  uint32_t frame=0;for(const auto &run:runs_)for(uint32_t i=0;i<run.frames;++i){
   if(frame%60==0 && !progress(frame,frames_))throw std::runtime_error("Saved-game loading cancelled");
   step(++frame,run.player1,run.player2);
  }
  if(!progress(frame,frames_))throw std::runtime_error("Saved-game loading cancelled");
 }
 // Shutdown recovery is bounded to the confirmed inputs since the last
 // trusted checkpoint. It must never replay speculative simulation history.
 template<class Step> void replayConfirmedTail(uint32_t after,Step step)const{
  if(after>frames_ || frames_-after>59)throw std::runtime_error("Invalid confirmed save tail");
  uint32_t end=0;for(const auto &run:runs_){uint32_t begin=end;end+=run.frames;
   for(uint32_t f=std::max(after,begin)+1;f<=end;++f)step(f,run.player1,run.player2);
  }
 }
 Bytes encode()const{
  validateIdentity(identity);if(!frames_ || runs_.empty())throw std::runtime_error("Cannot save an empty multiplayer game");
  Bytes b{'E','M','U','X','J','N','L','1'};appendValue(b,1,2);appendValue(b,0,2);appendValue(b,frames_,4);appendValue(b,runs_.size(),4);appendValue(b,identity.profile.size(),2);appendValue(b,0,2);
  for(const auto &d:{identity.rom,identity.runtime,identity.initialState,finalState})b.insert(b.end(),d.begin(),d.end());
  b.insert(b.end(),identity.profile.begin(),identity.profile.end());for(const auto &run:runs_){appendValue(b,run.frames,4);appendValue(b,run.player1,2);appendValue(b,run.player2,2);}
  auto digest=saveDigest(b);b.insert(b.end(),digest.begin(),digest.end());return b;
 }
 static SaveJournal decode(const Bytes &b,const SaveIdentity &expected){
  validateIdentity(expected);
  constexpr size_t fixed=24+128+32;
  if(b.size()<fixed || b.size()>MaxBytes || !std::equal(b.begin(),b.begin()+8,"EMUXJNL1"))throw std::runtime_error("Invalid multiplayer save format");
  Bytes body(b.begin(),b.end()-32);auto digest=saveDigest(body);if(!std::equal(digest.begin(),digest.end(),b.end()-32))throw std::runtime_error("Multiplayer save integrity check failed");
  Reader r{body};r.pos=8;if(r.get(2)!=1 || r.get(2)!=0)throw std::runtime_error("Unsupported multiplayer save version");
  auto frames=uint32_t(r.get(4)),count=uint32_t(r.get(4));unsigned profileLength=unsigned(r.get(2));
  if(r.get(2)!=0 || !frames || frames>MaxFrames || !count || count>MaxRuns || !profileLength || profileLength>128 || body.size()!=24+128+profileLength+size_t(count)*8)throw std::runtime_error("Invalid multiplayer save bounds");
  SaveJournal j;for(auto *d:{&j.identity.rom,&j.identity.runtime,&j.identity.initialState,&j.finalState})for(auto &value:*d)value=uint8_t(r.get(1));
  for(unsigned i=0;i<profileLength;++i)j.identity.profile+=char(r.get(1));validateIdentity(j.identity);
  if(!(j.identity==expected))throw std::runtime_error("Saved game requires the same ROM and runtime");
  uint64_t total=0;j.runs_.reserve(count);
  for(uint32_t i=0;i<count;++i){SaveRun run{uint32_t(r.get(4)),uint16_t(r.get(2)),uint16_t(r.get(2))};
   total+=run.frames;if(!run.frames || (run.player1|run.player2)>4095 || total>frames)throw std::runtime_error("Invalid saved-game input history");
   if(!j.runs_.empty() && run.player1==j.runs_.back().player1 && run.player2==j.runs_.back().player2)throw std::runtime_error("Noncanonical saved-game input history");
   j.runs_.push_back(run);
  }
  if(total!=frames)throw std::runtime_error("Incomplete saved-game input history");r.end();j.frames_=frames;return j;
 }
 void verifyFinal(const SaveDigest &actual)const{if(finalState!=actual)throw std::runtime_error("Saved-game replay state does not match");}
private:
 uint32_t frames_=0;std::vector<SaveRun> runs_;
 static void appendValue(Bytes &b,uint64_t value,unsigned bytes){emu::append(b,value,bytes);}
 static void validateIdentity(const SaveIdentity &id){
  if(id.profile.empty() || id.profile.size()>128 || !std::all_of(id.profile.begin(),id.profile.end(),[](unsigned char c){return c>=33 && c<=126;}))throw std::runtime_error("Invalid saved-game profile");
 }
};
// Each transfer is admitted by the authenticated host, with a fixed expected
// byte count and digest. Duplicate equal chunks are allowed; gaps, changed
// duplicates and overflows reject before any emulator operation is possible.
class SaveTransfer {
 static constexpr size_t Chunk=16384;
 size_t expected_=0;SaveDigest digest_{};Bytes bytes_;
public:
 void begin(size_t bytes,const SaveDigest &digest){if(expected_ || !bytes || bytes>SaveJournal::MaxBytes)throw std::runtime_error("Invalid saved-game transfer");expected_=bytes;digest_=digest;bytes_.reserve(bytes);}
 void put(size_t offset,const Bytes &chunk){
  if(!expected_ || chunk.empty() || chunk.size()>Chunk || offset>bytes_.size() || offset>expected_ || chunk.size()>expected_-offset)throw std::runtime_error("Invalid saved-game chunk");
  if(offset<bytes_.size()){if(chunk.size()>bytes_.size()-offset || !std::equal(chunk.begin(),chunk.end(),bytes_.begin()+offset))throw std::runtime_error("Conflicting saved-game chunk");return;}
  bytes_.insert(bytes_.end(),chunk.begin(),chunk.end());
 }
 bool complete()const{return expected_ && bytes_.size()==expected_;}
 const Bytes &finish()const{if(!complete() || saveDigest(bytes_)!=digest_)throw std::runtime_error("Incomplete or damaged saved-game transfer");return bytes_;}
 size_t received()const{return bytes_.size();}
 static constexpr size_t chunkSize(){return Chunk;}
};
// Serialization and disk I/O stay off simulation/audio threads. Only the newest
// confirmed checkpoint is queued. Readers see an old complete file or the new
// complete file, never a half-written save. submit copies a bounded RLE history.
class SaveWriter {
 std::string path_,error_;std::mutex mutex_;std::condition_variable wake_;
 std::unique_ptr<SaveJournal> latest_;bool stopping_=false,busy_=false;
 std::atomic<uint32_t> completed_{0};std::thread worker_;
public:
 explicit SaveWriter(std::string path);
 ~SaveWriter();
 SaveWriter(const SaveWriter&)=delete;SaveWriter&operator=(const SaveWriter&)=delete;
 void submit(const SaveJournal &journal);
 void flush();
 uint32_t completedFrames()const{return completed_.load();}
 std::string error();
};
Bytes readMultiplayerSave(const std::string &path);
void writeMultiplayerSave(const std::string &path,const Bytes &bytes);
}
