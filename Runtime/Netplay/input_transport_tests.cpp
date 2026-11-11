// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#include "input_transport.h"
#include <array>
#include <iostream>
using namespace emu;
static void require(bool value,const char *message){if(!value)throw std::runtime_error(message);}
template<class F> static void rejects(F fn){bool threw=false;try{fn();}catch(const std::exception &){threw=true;}require(threw,"Invalid packet accepted");}
static uint16_t mask(unsigned player,unsigned frame){return uint16_t(((frame%17==0)?4:0)|((frame%31<3)?8:0)|(player?32:16));}
int main(){try{
 InputTransport a,b;
 a.sample(1,4);auto first=a.packet();a.sample(2,0);auto second=a.packet();
 // Losing the first packet does not block delivery of the release or exact tap.
 auto got=b.receive(second,1);require(got==std::vector<InputTransport::Input>{{1,4},{2,0}},"Lost press was not recovered with release");
 require(b.receive(first,1).empty(),"Reordered duplicate was delivered twice");
 require(b.received()==2,"Receipt ACK is not cumulative");
 a.receive(b.packet(),3);require(a.drained(),"Acknowledgement did not retire history");
 a.receive(InputTransport{}.packet(),3);require(a.acknowledged()==2,"Old ACK regressed receipt state");
 auto conflict=first;conflict[10]=8;rejects([&]{b.receive(conflict,1);});
 auto futureAck=b.packet();futureAck[4]=3;rejects([&]{a.receive(futureAck,3);});
 require(a.drained(),"Malformed packet mutated valid state");
 rejects([&]{a.sample(4,0);});rejects([&]{a.sample(3,4096);});
 for(size_t n=0;n<second.size();n++){Bytes truncated(second.begin(),second.begin()+n);rejects([&]{b.receive(truncated,1);});}
 auto trailing=second;trailing.push_back(0);rejects([&]{b.receive(trailing,1);});
 InputTransport bounded;for(unsigned f=1;f<=InputTransport::Window;f++)bounded.sample(f,0);
 require(bounded.packet().size()==InputTransport::MaxPacketBytes,"Bundle escaped datagram budget");
 rejects([&]{bounded.sample(InputTransport::Window+1,0);});


 // Sparse arrivals cannot acknowledge a gap; later redundancy fills it once.
 auto bundle=[](unsigned last,unsigned ack,std::initializer_list<uint16_t> masks){Bytes bytes;append(bytes,last,4);append(bytes,ack,4);append(bytes,masks.size(),2);for(auto input:masks)append(bytes,input,2);return bytes;};
 InputTransport gaps;require(gaps.receive(bundle(2,0,{8}),1)==std::vector<InputTransport::Input>{{2,8}} && gaps.received()==0,"Sparse arrival ACK skipped a gap");
 require(gaps.receive(bundle(2,0,{4,8}),1)==std::vector<InputTransport::Input>{{1,4}} && gaps.received()==2,"Gap repair duplicated a delivered input");
 // Bound sparse input even when a caller supplies an excessively advanced frame.
 InputTransport malicious;rejects([&]{malicious.receive(bundle(121,0,{4}),10000);});
 require(malicious.received()==0,"Rejected future packet changed receipt");
 // Delayed packets outside the retained history are harmless and never replayed.
 InputTransport history;for(unsigned frame=1;frame<=250;++frame)history.receive(bundle(frame,0,{uint16_t(frame%4096)}),frame);
 require(history.receive(bundle(1,0,{1}),251).empty() && history.received()==250,"Old packet escaped duplicate suppression");
 // Validate the entire bundle before releasing acknowledged local history.
 InputTransport transactional;transactional.sample(1,4);auto invalid=bundle(1,1,{4096});rejects([&]{transactional.receive(invalid,1);});
 require(transactional.pending()==1 && transactional.received()==0,"Malformed mask applied its ACK");

 // Two paced peers, ~166 ms RTT, deterministic loss/reordering plus a short
 // burst. Retry even when frame production stops: deliberately lose final
 // data/ACK packets to exercise finite-run draining without reliable delivery.
 std::array<InputTransport,2> peers;
 struct Flight{unsigned due,to;Bytes bytes;};std::vector<Flight> flights;
 std::array<unsigned,2> produced{},delivered{};unsigned stalls=0,random=0x12345678;
 auto nextRandom=[&](){random^=random<<13;random^=random>>17;random^=random<<5;return random;};
 for(unsigned tick=0;tick<9100;++tick){
  for(size_t i=0;i<flights.size();){if(flights[i].due>tick){++i;continue;}
   auto flight=std::move(flights[i]);flights.erase(flights.begin()+i);
   for(auto [f,input]:peers[flight.to].receive(flight.bytes,produced[flight.to]+1)){
    require(input==mask(1-flight.to,f),"Frame input changed under loss/reordering");++delivered[flight.to];
   }
  }
  for(unsigned p=0;p<2;++p){
   if(produced[p]<9000){if(produced[p]+1<=peers[p].received()+12){++produced[p];peers[p].sample(produced[p],mask(p,produced[p]));}else ++stalls;}
   auto bytes=peers[p].packet();
   bool drop=nextRandom()%100==0 || (tick>=300 && tick<303) || (tick>=8999 && tick<9003);
   if(!drop)flights.push_back({tick+5+(nextRandom()%2),1-p,std::move(bytes)});
  }
  if(produced[0]==9000 && produced[1]==9000 && peers[0].drained() && peers[1].drained())break;
 }
 for(unsigned p=0;p<2;++p){require(peers[p].received()==9000 && peers[p].drained() && delivered[p]==9000,"Final input or receipt failed to drain");}
 require(stalls<12,"Loss repeatedly exhausted prediction horizon");
 std::cout<<"PASS redundant exact input, reorder/conflict/bounds, 9000-frame loss/burst/ACK drain; stalls="<<stalls<<"\n";
}catch(const std::exception &e){std::cerr<<e.what()<<"\n";return 1;}}
