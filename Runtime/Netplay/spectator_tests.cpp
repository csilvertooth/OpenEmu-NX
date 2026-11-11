// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#include "spectator_stream.h"
#include <iostream>
using namespace emu;
static void require(bool ok){if(!ok)throw std::runtime_error("spectator stream test failed");}
static void rejects(const Bytes &b){try{decodeStream(b);}catch(const std::exception&){return;}throw std::runtime_error("accepted malformed spectator packet");}
int main(){
 Bytes pixels(256*224*2),pcm(806*4);for(size_t i=0;i<pixels.size();i++)pixels[i]=uint8_t(i*13);for(size_t i=0;i<pcm.size();i++)pcm[i]=uint8_t(i*37);
 Bytes raw=pixels;raw.insert(raw.end(),pcm.begin(),pcm.end());uLongf size=compressBound(raw.size());Bytes zipped(size);require(compress2(zipped.data(),&size,raw.data(),raw.size(),1)==Z_OK);zipped.resize(size);
 auto packet=streamHeader(523,256,224,806);packet.insert(packet.end(),zipped.begin(),zipped.end());auto decoded=decodeStream(packet);require(decoded.frame==523 && decoded.pixels==pixels && decoded.audio==pcm);
 for(unsigned n=0;n<StreamHeaderBytes;n++)rejects(Bytes(packet.begin(),packet.begin()+n));
 auto bad=packet;bad.pop_back();rejects(bad);bad=packet;bad.push_back(0);rejects(bad);
 bad=packet;bad[0]=bad[1]=bad[2]=bad[3]=0;rejects(bad);bad=packet;bad[8]=0xff;bad[9]=0xff;rejects(bad);
 bad=packet;bad[8]=1;bad[9]=0;rejects(bad);bad=packet;bad[4]=0;bad[5]=0;rejects(bad);
 // Bundles are independently decodable after a missing packet or late join.
 auto later=packet;later[0]=0x12;later[1]=0x04;require(decodeStream(later).audio==pcm);
 // Simulate two lost packets; recover exact older PCM in chronological order.
 raw.insert(raw.end(),{3,4,5,6,7,8,9,10});size=compressBound(raw.size());zipped.resize(size);require(compress2(zipped.data(),&size,raw.data(),raw.size(),1)==Z_OK);zipped.resize(size);
 auto redundant=streamHeader(523,256,224,806,{1,1});redundant.insert(redundant.end(),zipped.begin(),zipped.end());decoded=decodeStream(redundant);
 require(decoded.previous[0]==Bytes({3,4,5,6}) && decoded.previous[1]==Bytes({7,8,9,10}));uint64_t recovered=0,missing=0;
 auto audio=streamAudio(decoded,decoded.frame-3,recovered,missing);Bytes expected{7,8,9,10,3,4,5,6};expected.insert(expected.end(),pcm.begin(),pcm.end());require(audio==expected && recovered==2 && missing==0);
 recovered=missing=0;require(streamAudio(decoded,0,recovered,missing)==pcm && recovered==0);
 recovered=missing=0;streamAudio(decoded,decoded.frame-5,recovered,missing);require(recovered==2 && missing==2);
 // Cover observed seven-to-nine-frame gaps and the full twelve-frame window.
 StreamBundle burst{100,256,224,pixels,pcm,{}};
 for(unsigned i=0;i<SpectatorHistory;++i)burst.previous[i]=Bytes(4,uint8_t(i+1));
 for(unsigned lost:{7u,8u,9u,SpectatorHistory}){
  recovered=missing=0;audio=streamAudio(burst,burst.frame-lost-1,recovered,missing);expected.clear();
  for(unsigned i=lost;i>0;--i)expected.insert(expected.end(),4,uint8_t(i));
  expected.insert(expected.end(),pcm.begin(),pcm.end());require(audio==expected && recovered==lost && missing==0);
 }
 recovered=missing=0;streamAudio(burst,burst.frame-SpectatorHistory-4,recovered,missing);require(recovered==SpectatorHistory && missing==3);
 // Encode/decode all history slots and reject an oversized final slot.
 raw=pixels;raw.insert(raw.end(),pcm.begin(),pcm.end());for(auto &block:burst.previous)raw.insert(raw.end(),block.begin(),block.end());
 size=compressBound(raw.size());zipped.resize(size);require(compress2(zipped.data(),&size,raw.data(),raw.size(),1)==Z_OK);zipped.resize(size);
 std::array<unsigned,SpectatorHistory> counts{};counts.fill(1);
 auto fullPacket=streamHeader(100,256,224,806,counts);fullPacket.insert(fullPacket.end(),zipped.begin(),zipped.end());
 auto full=decodeStream(fullPacket);require(full.previous==burst.previous);bad=fullPacket;bad[32]=bad[33]=255;rejects(bad);
 // Maximum legal decoded allocation is 551872 bytes, independent of compressed size.
 static_assert(StreamHeaderBytes==37 && StreamMaxDecodedBytes==551872);
 raw.assign(StreamMaxDecodedBytes,0);size=compressBound(raw.size());zipped.resize(size);
 require(compress2(zipped.data(),&size,raw.data(),raw.size(),1)==Z_OK);zipped.resize(size);
 counts.fill(SpectatorMaxSamples);auto maximum=streamHeader(100,512,478,SpectatorMaxSamples,counts);
 maximum.insert(maximum.end(),zipped.begin(),zipped.end());full=decodeStream(maximum);
 require(full.pixels.size()==512u*478u*2u && full.audio.size()==SpectatorMaxSamples*4u);
 for(const auto &block:full.previous)require(block.size()==SpectatorMaxSamples*4u);
 bad=maximum;bad.resize(StreamMaxPayloadBytes+1);rejects(bad);
 // Independent channel delta wraparound preserves every possible sample bit pattern.
 Bytes stereo(65536*4);for(unsigned i=0;i<65536;++i){streamPutWord(stereo,i*4,uint16_t(i));streamPutWord(stereo,i*4+2,uint16_t(65535-i));}
 require(streamPCMTransform(streamPCMTransform(stereo,false),true)==stereo);require(streamPCMTransform({},true).empty());
 // Exactly256 colors remain palette encodable;257 keeps pixels raw.
 Bytes colors(257*2),palette,indices;for(unsigned i=0;i<257;++i)streamPutWord(colors,i*2,uint16_t(i*251));
 Bytes limited(colors.begin(),colors.begin()+512);require(streamPalette(limited,palette,indices) && palette.size()==512 && indices.size()==256 && indices.back()==255);
 require(!streamPalette(colors,palette,indices) && palette.empty() && indices.empty());
 StreamBundle many{500,257,1,colors,Bytes({1,2,3,4}),{}};auto encoded=encodeStream(many);require(encoded[34]!=1 && decodeStream(encoded).pixels==colors);
 StreamBundle smooth{500,256,224,Bytes(256*224*2),Bytes(534*4),{}};
 for(unsigned y=0;y<224;++y)for(unsigned x=0;x<256;++x)streamPutWord(smooth.pixels,(y*256+x)*2,uint16_t((x/16)*0x0841));
 for(unsigned i=0;i<534;++i){streamPutWord(smooth.audio,i*4,uint16_t(i*63));streamPutWord(smooth.audio,i*4+2,uint16_t(65535-i*91));}
 for(unsigned i=0;i<SpectatorHistory;++i)smooth.previous[i]=smooth.audio;
 encoded=encodeStream(smooth);auto roundtrip=decodeStream(encoded);require(roundtrip.pixels==smooth.pixels && roundtrip.audio==smooth.audio && roundtrip.previous==smooth.previous);
 Bytes unfiltered=smooth.pixels;unfiltered.insert(unfiltered.end(),smooth.audio.begin(),smooth.audio.end());for(const auto &block:smooth.previous)unfiltered.insert(unfiltered.end(),block.begin(),block.end());
 require(encoded.size()<=StreamHeaderBytes+streamCompress(unfiltered).size());
 // Force palette decoding even if adaptive compression chooses raw.
 require(streamPalette(smooth.pixels,palette,indices));Bytes filtered=palette;filtered.insert(filtered.end(),indices.begin(),indices.end());
 auto delta=streamPCMTransform(smooth.audio,false);filtered.insert(filtered.end(),delta.begin(),delta.end());for(const auto &block:smooth.previous){delta=streamPCMTransform(block,false);filtered.insert(filtered.end(),delta.begin(),delta.end());}
 counts.fill(534);auto forcedHeader=streamHeader(500,256,224,534,counts,1,unsigned(palette.size()/2));
 auto wrap=[](Bytes header,const Bytes &body){auto zipped=streamCompress(body);header.insert(header.end(),zipped.begin(),zipped.end());return header;};
 auto forced=wrap(forcedHeader,filtered);roundtrip=decodeStream(forced);require(roundtrip.pixels==smooth.pixels && roundtrip.audio==smooth.audio && roundtrip.previous==smooth.previous);
 bad=forced;bad[34]=3;rejects(bad);bad=forced;bad[35]=bad[36]=0;rejects(bad);bad=forced;bad[35]=1;bad[36]=1;rejects(bad);
 auto invalid=filtered;invalid[palette.size()]=uint8_t(palette.size()/2);rejects(wrap(forcedHeader,invalid));
 invalid=filtered;invalid[2]=invalid[0];invalid[3]=invalid[1];rejects(wrap(forcedHeader,invalid));
 bad=forced;bad.pop_back();rejects(bad);bad=packet;bad[35]=1;rejects(bad);
 // Exercise the highest valid palette index through the decoder explicitly.
 counts.fill(0);Bytes all=limited;for(unsigned i=0;i<256;++i)all.push_back(uint8_t(i));auto onePCM=streamPCMTransform(Bytes({255,255,0,128}),false);all.insert(all.end(),onePCM.begin(),onePCM.end());
 auto palette256=wrap(streamHeader(1,256,1,1,counts,1,256),all);roundtrip=decodeStream(palette256);require(roundtrip.pixels==limited && roundtrip.audio==Bytes({255,255,0,128}));
 counts.fill(0);Bytes rawVideoDelta=colors;auto audioDelta=streamPCMTransform(many.audio,false);rawVideoDelta.insert(rawVideoDelta.end(),audioDelta.begin(),audioDelta.end());auto rawVideoPacket=wrap(streamHeader(500,257,1,1,counts,2,0),rawVideoDelta);roundtrip=decodeStream(rawVideoPacket);require(roundtrip.pixels==colors && roundtrip.audio==many.audio);
 auto malformed=smooth;malformed.previous.back().push_back(0);bool rejected=false;try{encodeStream(malformed);}catch(const std::exception&){rejected=true;}require(rejected);
 std::cout<<"PASS spectator PCM/video, late join, bounds, truncation, trailing data\n";
}
