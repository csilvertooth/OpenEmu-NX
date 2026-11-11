// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#pragma once
#include "wire.h"
#include <zlib.h>
#include <array>
#include <algorithm>
namespace emu {
// Version 8, message 8: one picture plus PCM from the same simulation
// frame, at the core's native approximately 60 Hz. Stereo PCM16 little endian, 32040 Hz. Independently
// compressed bundles allow immediate late joins and loss recovery.
inline constexpr unsigned SpectatorHistory=12;
inline constexpr unsigned StreamHeaderBytes=13+2*SpectatorHistory;
inline constexpr unsigned SpectatorMaxSamples=1200;
// The message-type byte also fits inside GNS's 300000-byte message limit.
inline constexpr size_t StreamMaxPayloadBytes=299999;
inline constexpr size_t StreamMaxDecodedBytes=512u*478u*2u+(SpectatorHistory+1)*SpectatorMaxSamples*4u;
struct StreamBundle { unsigned frame,width,height; Bytes pixels,audio;std::array<Bytes,SpectatorHistory> previous; };
inline Bytes streamHeader(unsigned frame,unsigned width,unsigned height,unsigned samples,const std::array<unsigned,SpectatorHistory> &previous={},unsigned codec=0,unsigned paletteCount=0) {
 Bytes b;append(b,frame,4);append(b,width,2);append(b,height,2);append(b,samples,2);
 for(unsigned count:previous)append(b,count,2);append(b,codec,1);append(b,paletteCount,2);return b;
}
// Codec 1 is a packet-local <=256-entry palette plus independent left/right
// PCM deltas. Codec 2 keeps raw pixels with the same PCM transform. All 16 bits of every pixel and sample survive exactly.
inline uint16_t streamWord(const Bytes &b,size_t offset){return uint16_t(b[offset])|(uint16_t(b[offset+1])<<8);}
inline void streamPutWord(Bytes &b,size_t offset,uint16_t word){b[offset]=uint8_t(word);b[offset+1]=uint8_t(word>>8);}
inline bool streamPalette(const Bytes &pixels,Bytes &palette,Bytes &indices){
 if(pixels.empty() || pixels.size()%2)throw std::runtime_error("Invalid spectator palette input");
 std::array<int16_t,65536> lookup;lookup.fill(-1);palette.clear();indices.clear();indices.reserve(pixels.size()/2);
 for(size_t i=0;i<pixels.size();i+=2){uint16_t color=streamWord(pixels,i);int index=lookup[color];
  if(index<0){if(palette.size()==512){palette.clear();indices.clear();return false;}index=int(palette.size()/2);lookup[color]=int16_t(index);append(palette,color,2);}
  indices.push_back(uint8_t(index));
 }
 return true;
}
inline Bytes streamPCMTransform(const Bytes &input,bool inverse){
 if(input.size()%4)throw std::runtime_error("Invalid spectator audio transform");
 const size_t samples=input.size()/4;Bytes output(input.size());uint16_t previous[2]={0,0};
 for(size_t i=0;i<samples;++i)for(unsigned channel=0;channel<2;++channel){size_t plane=channel*2*samples;
  if(inverse){uint16_t delta=uint16_t(input[plane+i])|(uint16_t(input[plane+samples+i])<<8);uint16_t sample=uint16_t(previous[channel]+delta);streamPutWord(output,i*4+channel*2,sample);previous[channel]=sample;}
  else{uint16_t sample=streamWord(input,i*4+channel*2),delta=uint16_t(sample-previous[channel]);output[plane+i]=uint8_t(delta);output[plane+samples+i]=uint8_t(delta>>8);previous[channel]=sample;}
 }
 return output;
}
inline Bytes streamCompress(const Bytes &raw){uLongf size=compressBound(raw.size());Bytes zipped(size);if(compress2(zipped.data(),&size,raw.data(),raw.size(),1)!=Z_OK)throw std::runtime_error("Cannot encode spectator payload");zipped.resize(size);return zipped;}
// Choose the smaller independent representation. Empty means a valid but
// incompressible picture exceeds the transport cap and should be dropped.
inline Bytes encodeStream(const StreamBundle &bundle){
 if(!bundle.frame || !bundle.width || bundle.width>512 || !bundle.height || bundle.height>478 || bundle.pixels.size()!=size_t(bundle.width)*bundle.height*2 || bundle.audio.empty() || bundle.audio.size()%4 || bundle.audio.size()>SpectatorMaxSamples*4)throw std::runtime_error("Invalid spectator encoder input");
 std::array<unsigned,SpectatorHistory> counts{};
 Bytes palette,indices;bool indexed=streamPalette(bundle.pixels,palette,indices);Bytes raw=bundle.pixels,transformed=bundle.pixels;
 if(indexed){transformed=palette;transformed.insert(transformed.end(),indices.begin(),indices.end());}
 auto add=[&](const Bytes &pcm){raw.insert(raw.end(),pcm.begin(),pcm.end());auto delta=streamPCMTransform(pcm,false);transformed.insert(transformed.end(),delta.begin(),delta.end());};
 add(bundle.audio);
 for(unsigned i=0;i<SpectatorHistory;++i){const auto &pcm=bundle.previous[i];if(pcm.size()%4 || pcm.size()>SpectatorMaxSamples*4)throw std::runtime_error("Invalid spectator encoder history");counts[i]=unsigned(pcm.size()/4);add(pcm);}
 auto zipped=streamCompress(raw);unsigned codec=0;
 auto filtered=streamCompress(transformed);if(filtered.size()<zipped.size()){codec=indexed?1:2;zipped=std::move(filtered);}
 if(StreamHeaderBytes+zipped.size()>StreamMaxPayloadBytes)return {};
 auto result=streamHeader(bundle.frame,bundle.width,bundle.height,unsigned(bundle.audio.size()/4),counts,codec,codec==1?unsigned(palette.size()/2):0);result.insert(result.end(),zipped.begin(),zipped.end());return result;
}
inline StreamBundle decodeStream(const Bytes &b) {
 Reader r{b};unsigned frame=r.get(4),w=r.get(2),h=r.get(2),samples=r.get(2);
 std::array<unsigned,SpectatorHistory> previous{};size_t previousSamples=0;
 for(auto &count:previous){count=r.get(2);if(count>SpectatorMaxSamples)throw std::runtime_error("Invalid spectator history");previousSamples+=count;}
 unsigned codec=r.get(1),paletteCount=r.get(2);if(codec>2)throw std::runtime_error("Unknown spectator codec");
 if(!frame || !w || w>512 || !h || h>478 || !samples || samples>SpectatorMaxSamples || b.size()>StreamMaxPayloadBytes || b.size()<=StreamHeaderBytes)
  throw std::runtime_error("Invalid spectator bundle");
 if((codec!=1 && paletteCount) || (codec==1 && (!paletteCount || paletteCount>256 || paletteCount>size_t(w)*h)))throw std::runtime_error("Invalid spectator palette count");
 // Snes9x delivery blocks can exceed a nominal 534-sample frame (e.g.
 // 806 at startup and 635 during the SMK demo transition).
 const size_t pixelCount=size_t(w)*h,videoBytes=pixelCount*2;const size_t encodedVideoBytes=codec==1?paletteCount*2+pixelCount:videoBytes;const size_t rawBytes=encodedVideoBytes+(samples+previousSamples)*4;
 if(rawBytes>StreamMaxDecodedBytes)throw std::runtime_error("Invalid spectator decoded size");
 Bytes raw(rawBytes);
 z_stream z{};z.next_in=const_cast<Bytef*>(b.data()+StreamHeaderBytes);z.avail_in=b.size()-StreamHeaderBytes;z.next_out=raw.data();z.avail_out=raw.size();
 if(inflateInit(&z)!=Z_OK)throw std::runtime_error("Cannot decode spectator bundle");
 int result=inflate(&z,Z_FINISH);bool valid=result==Z_STREAM_END && z.total_out==raw.size() && z.avail_in==0;inflateEnd(&z);
 if(!valid)throw std::runtime_error("Invalid spectator payload");
 Bytes pixels;
 if(codec==1){pixels.resize(videoBytes);std::array<bool,65536> used{};
  for(unsigned i=0;i<paletteCount;++i){auto color=streamWord(raw,i*2);if(used[color])throw std::runtime_error("Duplicate spectator palette color");used[color]=true;}
  for(size_t i=0;i<pixelCount;++i){unsigned index=raw[paletteCount*2+i];if(index>=paletteCount)throw std::runtime_error("Invalid spectator palette index");streamPutWord(pixels,i*2,streamWord(raw,index*2));}
 }else pixels=Bytes(raw.begin(),raw.begin()+videoBytes);
 auto current=raw.begin()+encodedVideoBytes,history=current+samples*4;
 StreamBundle resultBundle{frame,w,h,std::move(pixels),Bytes(current,history),{}};
 for(unsigned i=0;i<SpectatorHistory;++i){auto end=history+previous[i]*4;resultBundle.previous[i]=Bytes(history,end);history=end;}
 if(codec){resultBundle.audio=streamPCMTransform(resultBundle.audio,true);for(auto &pcm:resultBundle.previous)pcm=streamPCMTransform(pcm,true);}
 return resultBundle;
}
// Recover up to twelve missing frame blocks without retransmission or waiting.
// Older duplicates are discarded by the caller before invoking this function.
inline Bytes streamAudio(const StreamBundle &b,unsigned completed,uint64_t &recovered,uint64_t &missing){
 Bytes audio;unsigned gap=completed && b.frame>completed?b.frame-completed-1:0;
 for(unsigned back=std::min(gap,SpectatorHistory);back>0;--back){const auto &block=b.previous[back-1];if(!block.empty()){audio.insert(audio.end(),block.begin(),block.end());++recovered;}else ++missing;}
 if(gap>SpectatorHistory)missing+=gap-SpectatorHistory;
 audio.insert(audio.end(),b.audio.begin(),b.audio.end());return audio;
}
}
