// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#pragma once
#include <steam/steamnetworkingcustomsignaling.h>
// Included after the shared HTTP/JSON helpers. GNS callbacks only enqueue;
// authenticated HTTP runs on this worker, never on simulation or audio threads.
struct SignalMailbox {
 std::mutex mutex;std::condition_variable wake;bool stopping=false;
 std::deque<NSDictionary *> outbound,inbound;std::string error;
 bool enqueue(const std::string &target,const void *data,int size){
  if(size<=0 || size>4096)return false;
  @autoreleasepool{NSData *bytes=[NSData dataWithBytes:data length:size];
   NSDictionary *message=@{@"to":ns(target),@"payload":[bytes base64EncodedStringWithOptions:0]};
   std::lock_guard<std::mutex> lock(mutex);if(stopping || outbound.size()>=64)return false;outbound.push_back(message);wake.notify_one();return true;
  }
 }
};
class LobbySignaler:public ISteamNetworkingConnectionSignaling {
 std::shared_ptr<SignalMailbox> mailbox;std::string target;
public:
 LobbySignaler(std::shared_ptr<SignalMailbox> m,std::string t):mailbox(std::move(m)),target(std::move(t)){}
 bool SendSignal(HSteamNetConnection,const SteamNetConnectionInfo_t &,const void *data,int size) override{return mailbox->enqueue(target,data,size);}
 void Release() override{delete this;}
};
class SignalReceiver:public ISteamNetworkingSignalingRecvContext {
 std::shared_ptr<SignalMailbox> mailbox;std::string sender;bool accepts;
public:
 SignalReceiver(std::shared_ptr<SignalMailbox> m,std::string s,bool a):mailbox(std::move(m)),sender(std::move(s)),accepts(a){}
 ISteamNetworkingConnectionSignaling *OnConnectRequest(HSteamNetConnection,const SteamNetworkingIdentity &peer,int port) override{
  char identity[SteamNetworkingIdentity::k_cchMaxString];peer.ToString(identity,sizeof(identity));
  if(!accepts || port!=0 || sender!=identity)return nullptr;
  return new LobbySignaler(mailbox,sender);
 }
 void SendRejectionSignal(const SteamNetworkingIdentity &,const void *,int) override{}
};
class SignalWorker {
 std::shared_ptr<SignalMailbox> mailbox;std::thread worker;
public:
 SignalWorker(std::shared_ptr<SignalMailbox> box,std::string session,bool idempotent):mailbox(box),worker([box,session,idempotent]{
  std::unique_lock<std::mutex> lock(box->mutex);LobbyRetry retry;
  NSDictionary *__strong pending=nil;
  while(!box->stopping){@autoreleasepool{
   if(!pending){NSMutableArray *sending=[NSMutableArray array];
    while(!box->outbound.empty() && sending.count<2){[sending addObject:box->outbound.front()];box->outbound.pop_front();}
    NSMutableDictionary *request=[@{@"session_id":ns(session),@"messages":sending} mutableCopy];
    if(idempotent)request[@"request_id"]=NSUUID.UUID.UUIDString.lowercaseString;pending=request;retry.begin(Clock::now());
   }
   auto interval=std::chrono::milliseconds(250);
   lock.unlock();@autoreleasepool{try{
    if(!retry.canAttempt(Clock::now()))throw std::runtime_error("Lobby signaling retry deadline exceeded");
    NSDictionary *result=api(@"signals",@"POST",pending);
    NSArray *messages=result[@"messages"];if(![messages isKindOfClass:NSArray.class] || messages.count>16)throw std::runtime_error("Invalid signaling response");
    lock.lock();if(box->inbound.size()+messages.count>64)throw std::runtime_error("Signaling receive queue full");
    for(NSDictionary *message in messages)box->inbound.push_back(message);
    pending=nil;retry.succeeded();signalRetrying=false;
   }catch(const LobbyHTTPError &e){if(!lock.owns_lock())lock.lock();if(!idempotent || !retry.failed(e.status,Clock::now())){box->error=e.what();return;}++signalTransientRetries;signalRetrying=true;interval=retry.delay();}
    catch(const std::exception &e){if(!lock.owns_lock())lock.lock();box->error=e.what();return;}}
   // Retain the same bounded batch/id until its response is acknowledged.
   // Server replay caching prevents response loss from consuming inbound twice.
   box->wake.wait_for(lock,interval,[&]{return box->stopping;});
  }}
 }){}
 void stop(){{std::lock_guard<std::mutex> lock(mailbox->mutex);mailbox->stopping=true;}mailbox->wake.notify_one();}
 ~SignalWorker(){stop();if(worker.joinable())worker.join();}
 void poll(ISteamNetworkingSockets *sockets,bool accepts){
  std::deque<NSDictionary *> messages;{std::lock_guard<std::mutex> lock(mailbox->mutex);if(!mailbox->error.empty())throw std::runtime_error(mailbox->error);messages.swap(mailbox->inbound);}
  for(NSDictionary *message:messages){
   if(![message[@"from"] isKindOfClass:NSString.class] || ![message[@"payload"] isKindOfClass:NSString.class])throw std::runtime_error("Invalid signal envelope");
   NSData *data=[[NSData alloc]initWithBase64EncodedString:message[@"payload"] options:0];if(!data || !data.length || data.length>4096)throw std::runtime_error("Invalid signal payload");
   SignalReceiver context(mailbox,str(message[@"from"]),accepts);sockets->ReceivedP2PCustomSignal(data.bytes,int(data.length),&context);
  }
 }
};
