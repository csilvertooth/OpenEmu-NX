// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#pragma once
#include "wire.h"
#include <algorithm>
#include <limits>
#include <map>
#include <utility>
namespace emu {
// One simulation owner. Rollback input is not a reliable ordered stream: a
// dropped datagram must not hold newer frame inputs behind a retransmission.
// Every datagram repeats ALL unacknowledged exact input masks. Receipt ACKs are
// cumulative (not predicted/confirmed-frame ACKs) and ride every retry, including
// when simulation is stalled or has reached its finite test endpoint.
class InputTransport {
public:
 static constexpr unsigned Window=120,MaxPacketBytes=10+Window*2;
 using Input=std::pair<unsigned,uint16_t>;
 unsigned latest()const{return latest_;}
 unsigned received()const{return received_;}
 unsigned acknowledged()const{return acknowledged_;}
 unsigned pending()const{return latest_-acknowledged_;}
 bool drained()const{return acknowledged_==latest_;}
 unsigned duplicateInputs=0;
 void sample(unsigned frame,uint16_t mask){
  if(frame!=latest_+1 || latest_==std::numeric_limits<unsigned>::max() || mask>4095 || pending()>=Window)
   throw std::runtime_error("Invalid or excessive pending local input");
  outbound_.emplace(frame,mask);latest_=frame;
 }
 Bytes packet()const{
  Bytes result;append(result,latest_,4);append(result,received_,4);append(result,outbound_.size(),2);
  for(auto [frame,mask]:outbound_)append(result,mask,2);
  return result;
 }
 std::vector<Input> receive(const Bytes &bytes,unsigned nextFrame){
  if(bytes.size()<10 || bytes.size()>MaxPacketBytes)throw std::runtime_error("Invalid input bundle size");
  Reader reader{bytes};unsigned last=reader.get(4),ack=reader.get(4),count=reader.get(2);
  if(count>Window || count>last || ack>latest_ || uint64_t(last)>uint64_t(nextFrame)+Window || uint64_t(last)>uint64_t(received_)+Window || bytes.size()!=10+count*2)
   throw std::runtime_error("Invalid input bundle bounds or acknowledgement");
  // A sender cannot legitimately get more than Window beyond our cumulative
  // receipt: its own unacknowledged history has that same limit. This also
  // bounds sparse adversarial input independently of simulation progression.
  std::vector<Input> incoming;incoming.reserve(count);
  unsigned first=count?last-count+1:0;
  for(unsigned i=0;i<count;++i){
   unsigned frame=first+i;uint16_t mask=reader.get(2);
   if(mask>4095)throw std::runtime_error("Invalid input bundle mask");
   // A delayed datagram older than retained receipt history cannot contribute
   // a new input or regress an ACK. Ignore it rather than killing the session.
   if(frame<received_ && received_-frame>Window)continue;
   auto old=inbound_.find(frame);
   if(old!=inbound_.end()){
    if(old->second!=mask)throw std::runtime_error("Conflicting input bundle duplicate");
   }else if(frame<=received_)throw std::runtime_error("Missing input receipt history");
   else incoming.emplace_back(frame,mask);
  }
  reader.end();
  // Do not release pending local input until the whole packet was validated.
  if(ack>acknowledged_){acknowledged_=ack;while(!outbound_.empty() && outbound_.begin()->first<=ack)outbound_.erase(outbound_.begin());}
  duplicateInputs+=count-unsigned(incoming.size());
  for(auto [frame,mask]:incoming)inbound_.emplace(frame,mask);
  while(received_!=std::numeric_limits<unsigned>::max() && inbound_.count(received_+1))++received_;
  while(!inbound_.empty() && inbound_.begin()->first<received_ && received_-inbound_.begin()->first>Window)inbound_.erase(inbound_.begin());
  return incoming;
 }
private:
 unsigned latest_=0,received_=0,acknowledged_=0;
 std::map<unsigned,uint16_t> outbound_,inbound_;
};
}
