// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <steam/steamnetworkingsockets.h>
#include <steam/isteamnetworkingutils.h>
#include <openssl/sha.h>
#include <zlib.h>
#include "emu_runtime.h"
#include "lockstep.h"
#include "input_timing.h"
#include "rollback.h"
#include "multiplayer_save.h"
#include "input_transport.h"
#include "lobby_retry.h"
#include "wire.h"
#include "spectator_stream.h"
#include "audio_ring.h"
#include "presentation_clock.h"
#include <chrono>
#include <cmath>
#include <fstream>
#include <iostream>
#include <sstream>
#include <iomanip>
#include <thread>
#include <atomic>
#include <memory>
#include <mutex>
#include <condition_variable>
#include <deque>
#include <dlfcn.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
using namespace emu;
using Clock=std::chrono::steady_clock;
static std::string str(NSString *s){return s ? s.UTF8String : "";}
static NSString *ns(const std::string &s){return [NSString stringWithUTF8String:s.c_str()];}
static Bytes readFile(const std::string &p){std::ifstream f(p,std::ios::binary|std::ios::ate);if(!f || f.tellg()<0 || f.tellg()>32*1024*1024)throw std::runtime_error("Cannot read game/runtime");Bytes b((size_t)f.tellg());f.seekg(0);f.read((char*)b.data(),b.size());if(!f)throw std::runtime_error("Read failed");return b;}
static std::string hash(const Bytes &b){unsigned char h[32];SHA256(b.data(),b.size(),h);std::ostringstream o;for(auto c:h)o<<std::hex<<std::setw(2)<<std::setfill('0')<<unsigned(c);return o.str();}
static void check(int r){if(r)throw std::runtime_error("Emulation runtime failed");}
static Bytes json(NSDictionary *d){NSData *data=[NSJSONSerialization dataWithJSONObject:d options:0 error:nil];auto p=(const uint8_t*)data.bytes;return Bytes(p,p+data.length);}
static NSDictionary *object(const Bytes &b){if(b.size()>131072)throw std::runtime_error("Oversized control message");id o=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:b.data() length:b.size()] options:0 error:nil];if(![o isKindOfClass:NSDictionary.class])throw std::runtime_error("Invalid control message");return o;}
@interface NoRedirect : NSObject<NSURLSessionTaskDelegate>
@end
@implementation NoRedirect
-(void)URLSession:(NSURLSession*)s task:(NSURLSessionTask*)t willPerformHTTPRedirection:(NSHTTPURLResponse*)r newRequest:(NSURLRequest*)q completionHandler:(void(^)(NSURLRequest*))done {done(nil);}
@end
static NSDictionary *config;
static NSURLSession *http;
static std::atomic<int64_t> installedTURNExpiresAt{0};
static void validateLobbyOrigin(){
 NSURLComponents *url=[NSURLComponents componentsWithString:config[@"endpoint"]];
 bool localTest=[config[@"local_test_mode"] boolValue] && [url.scheme.lowercaseString isEqual:@"http"] && ([url.host.lowercaseString isEqual:@"127.0.0.1"] || [url.host.lowercaseString isEqual:@"localhost"]);
 if((![url.scheme.lowercaseString isEqual:@"https"] && !localTest) || !url.host.length || url.user || url.password || url.query || url.fragment || (url.path.length && ![url.path isEqual:@"/"]))throw std::runtime_error("Network play requires an HTTPS lobby origin");
 // The helper needs only room membership and a relay credential obtained
 // once when connecting. Legacy installation secrets are not accepted.
 if(config[@"installation_secret"] || config[@"installation_id"])throw std::runtime_error("Update the frontend before starting network play");
}
static NSArray *validatedICEServers(id value){
 if(![value isKindOfClass:NSArray.class] || [value count]>4)throw std::runtime_error("Invalid ICE server list");
 NSRegularExpression *pattern=[NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9.-]{1,253}:[0-9]{1,5}$" options:0 error:nil];
 for(id entry in value){
  if(![entry isKindOfClass:NSString.class] || [pattern numberOfMatchesInString:entry options:0 range:NSMakeRange(0,[entry length])]!=1)throw std::runtime_error("Invalid ICE server address");
  NSInteger port=[[[entry componentsSeparatedByString:@":"] lastObject] integerValue];
  if(port<1 || port>65535)throw std::runtime_error("Invalid ICE server port");
 }
 return value;
}
static NSDictionary *connectionSettings(NSDictionary *admission,bool allowRelay,bool requireRelay){
 id network=admission[@"network"];
 if(![network isKindOfClass:NSDictionary.class])throw std::runtime_error("Lobby does not provide ICE settings");
 NSArray *stun=validatedICEServers(network[@"stun_servers"]);
 NSMutableDictionary *settings=[@{@"stun_servers":stun,@"turn_servers":@[]} mutableCopy];
 // Normal session polls never authorize relay use. Ignore their TURN fields,
 // including replies from an older lobby, and use only the explicit grant.
 id grant=config[@"relay_network"];
 if(!allowRelay || !grant){
  if(requireRelay)throw std::runtime_error("Connect again to request relay access");
  return settings;
 }
 if(![grant isKindOfClass:NSDictionary.class])throw std::runtime_error("Invalid relay authorization");
 NSArray *turn=validatedICEServers(grant[@"turn_servers"]);
 id username=grant[@"turn_username"],password=grant[@"turn_password"],expiry=grant[@"turn_expires_at"];
 if(!turn.count || ![username isKindOfClass:NSString.class] || ![password isKindOfClass:NSString.class] || ![expiry isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)expiry)==CFBooleanGetTypeID())throw std::runtime_error("Incomplete relay authorization");
 double expires=[expiry doubleValue],now=NSDate.date.timeIntervalSince1970;
 if(!std::isfinite(expires) || expires!=std::floor(expires) || expires<=now || expires>now+14430)throw std::runtime_error("Relay authorization expired or has an invalid lifetime; connect again");
 NSCharacterSet *userChars=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:_-."];
 NSCharacterSet *passwordChars=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/="];
 if(![username length] || [username length]>512 || [username rangeOfCharacterFromSet:userChars.invertedSet].location!=NSNotFound || ![password length] || [password length]>256 || [password rangeOfCharacterFromSet:passwordChars.invertedSet].location!=NSNotFound)throw std::runtime_error("Invalid relay credential encoding");
 NSString *prefix=[NSString stringWithFormat:@"%lld:%@:",[expiry longLongValue],config[@"room_id"]];
 if(![username hasPrefix:prefix])throw std::runtime_error("Relay authorization belongs to a different room");
 settings[@"turn_servers"]=turn;settings[@"turn_username"]=username;settings[@"turn_password"]=password;settings[@"turn_expires_at"]=expiry;
 return settings;
}
static double requestSecondsLeft(Clock::time_point deadline){double remaining=std::chrono::duration<double>(deadline-Clock::now()).count();if(remaining<=0)throw LobbyHTTPError(0,"Lobby operation deadline reached");return std::min(4.0,remaining);}
static bool waitHTTP(dispatch_semaphore_t done,Clock::time_point deadline){auto remaining=std::chrono::duration_cast<std::chrono::nanoseconds>(deadline-Clock::now()).count();return remaining<=0 || dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,remaining));}
static NSDictionary *apiAttempt(NSString *action,NSString *method,NSDictionary *body,Clock::time_point deadline){
 NSString *url=[NSString stringWithFormat:@"%@/v1/rooms/%@/%@",config[@"endpoint"],config[@"room_id"],action];
 NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];r.HTTPMethod=method;r.timeoutInterval=requestSecondsLeft(deadline);
 [r setValue:[@"Bearer " stringByAppendingString:config[@"token"]] forHTTPHeaderField:@"Authorization"];
 [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
 if(body)r.HTTPBody=[NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
 dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSData *data=nil;__block NSInteger code=0;
 NSURLSessionDataTask *task=[http dataTaskWithRequest:r completionHandler:^(NSData *d,NSURLResponse *response,NSError *e){data=d;code=e?0:((NSHTTPURLResponse*)response).statusCode;dispatch_semaphore_signal(done);}];[task resume];
 if(waitHTTP(done,deadline)){[task cancel];throw LobbyHTTPError(0,"Lobby request timed out");}
 if(code==409 && data.length<131072){id detail=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];if([detail isKindOfClass:NSDictionary.class] && [detail[@"error"] isEqual:@"relay_unavailable"])throw std::runtime_error("Relay service is not configured for this lobby");}
 if(code<200 || code>=300 || data.length>131072){
  std::string reason="unavailable";
  if(data.length && data.length<=131072){id detail=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
   if([detail isKindOfClass:NSDictionary.class] && [detail[@"error"] isKindOfClass:NSString.class]){
    NSString *value=detail[@"error"];NSCharacterSet *safe=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz_"];
    if(value.length<=64 && [value rangeOfCharacterFromSet:safe.invertedSet].location==NSNotFound)reason=str(value);
   }}
  if(code==404 && reason=="room_unavailable")
   throw LobbyHTTPError(int(code),"This room has closed or expired. Create or join a room to play again.");
  if(code==409 && reason=="stale_session")
   throw LobbyHTTPError(int(code),"This network game has ended. Reconnect when both players are ready.");
  throw LobbyHTTPError(int(code),"Lobby "+str(action)+": "+reason+" ("+std::to_string(code)+")");
 }
 auto p=(const uint8_t*)data.bytes;return object(Bytes(p,p+data.length));
}
static NSDictionary *api(NSString *action,NSString *method,NSDictionary *body=nil){
 // Room membership requests remain bounded and run on control workers. Relay
 // access was requested once before launch; no credential refresh or
 // installation check is performed during gameplay.
 return apiAttempt(action,method,body,Clock::now()+std::chrono::seconds(5));
}
static std::atomic<uint64_t> lobbyTransientRetries{0},signalTransientRetries{0};
static std::atomic<bool> lobbyRetrying{false},signalRetrying{false};
#include "lobby_signaling.h"
static std::string connectionFailure;
static std::atomic<int> selectedRoute{0},networkRTT{-1};
static std::atomic<double> networkQuality{1};
static uint16_t keys=0;
static std::atomic<bool> closing{false};
static volatile sig_atomic_t terminationRequested=0;
static void requestTermination(int){terminationRequested=1;}
static bool closeRequested(){if(terminationRequested)closing=true;return closing.load();}
static std::atomic<uint16_t> liveInput{0};
static std::atomic<double> inputDelayMS{0}, inputQueueMS{0}, hostStartOffsetMS{0};
static std::atomic<double> sessionFPS{0};
static AudioRing playback;
static std::atomic<bool> rollbackPlayer{false};
static std::atomic<unsigned> saveCompletedFrame{0},resumeFrame{0},resumeTotal{0};
static std::mutex saveStatusMutex;static std::string saveError;
static std::atomic<unsigned> rollbackCount{0},rollbackFrames{0},rollbackDepth{0},confirmedFrame{0};
static PresentationClock videoClock;
static std::atomic<uint64_t> discardedPictures{0};
static std::atomic<uint64_t> streamGaps{0},streamFrames{0},recoveredAudio{0},unrecoveredAudio{0};
struct QueuedPicture {Bytes pixels;unsigned width,height,frame;std::string role;double sample,deadline;};
struct Presentation {
 std::mutex mutex;
 std::deque<QueuedPicture> pictures;
 FrameTimeline timeline;
 PlayerTimeline playerTimeline;
} presentation;
static void presentFrame(const Bytes &pixels,unsigned width,unsigned height,unsigned frame,const std::string &role,const emu_frame *sound=nullptr,unsigned pictureSamples=0){
 if([config[@"headless"] boolValue])return;
 uint64_t end=playback.position();if(sound && sound->audio_frames)end=playback.push(sound->audio,sound->audio_frames);
 std::lock_guard<std::mutex> lock(presentation.mutex);
 // Video follows the device's consumed sample position, not packet arrival.
 // Each picture and audio block now represents one simulation frame.
 uint64_t offset=pictureSamples?pictureSamples:(sound?sound->audio_frames:0);
 double sample=presentation.timeline.position(frame,end>=offset?end-offset:0);
 double due=presentation.playerTimeline.deadline(frame,CACurrentMediaTime());
 presentation.pictures.push_back({pixels,width,height,frame,role,sample,due});
 // Include the watcher prebuffer and device presentation latency.
 while(presentation.pictures.size()>32){presentation.pictures.pop_front();++discardedPictures;}
}

@interface GameView : NSView
@property NSImage *picture;
@property unsigned sourceFrame,lastDrawnFrame;
@property uint64_t drawnFrames;
@property double firstDraw,lastDraw,maximumDrawGap,maximumPlaybackDrawGap;
@property uint64_t playbackDrawStalls,playbackMicrostutters;
@end
@implementation GameView
-(BOOL)acceptsFirstResponder{return YES;}
-(void)drawRect:(NSRect)rect{[NSColor.blackColor setFill];NSRectFill(self.bounds);if(_picture){CGFloat scale=MIN(self.bounds.size.width/_picture.size.width,self.bounds.size.height/_picture.size.height);NSSize size=NSMakeSize(_picture.size.width*scale,_picture.size.height*scale);NSRect dst=NSMakeRect((self.bounds.size.width-size.width)/2,(self.bounds.size.height-size.height)/2,size.width,size.height);NSGraphicsContext.currentContext.imageInterpolation=NSImageInterpolationNone;[_picture drawInRect:dst];if(_sourceFrame!=_lastDrawnFrame){double now=std::chrono::duration<double>(Clock::now().time_since_epoch()).count();if(_drawnFrames){double gap=now-_lastDraw;_maximumDrawGap=MAX(_maximumDrawGap,gap);/* The first picture precedes audio prebuffering. */if(_drawnFrames>1){_maximumPlaybackDrawGap=MAX(_maximumPlaybackDrawGap,gap);if(gap>0.050)++_playbackDrawStalls;if(gap>0.025)++_playbackMicrostutters;}}else _firstDraw=now;_lastDraw=now;_lastDrawnFrame=_sourceFrame;++_drawnFrames;}}}
-(void)setKey:(NSEvent*)event down:(BOOL)down{const unsigned codes[]={126,125,123,124,7,6,1,0,12,13,36,48};for(unsigned i=0;i<12;i++)if(event.keyCode==codes[i]){if(down)keys|=1<<i;else keys&=~(1<<i);}}
-(void)keyDown:(NSEvent*)e{[self setKey:e down:YES];}
-(void)keyUp:(NSEvent*)e{[self setKey:e down:NO];}
@end
@interface DisplayDriver : NSObject
@property(copy) void (^update)(CADisplayLink *);
@end
@implementation DisplayDriver
-(void)display:(CADisplayLink *)link{if(_update)_update(link);}
@end

// AppKit's synchronous zoom animation can hold the main loop for hundreds
// of milliseconds. Resize game windows immediately so playback keeps drawing.
@interface GameWindow : NSWindow
@end
@implementation GameWindow
-(NSTimeInterval)animationResizeTime:(NSRect)newFrame{return 0;}
@end
@interface WindowDelegate : NSObject<NSWindowDelegate>
@end
@implementation WindowDelegate
-(void)windowWillClose:(NSNotification*)n{closing=true;}
-(void)windowDidResignKey:(NSNotification*)n{keys=0;}
@end
static uint16_t controller(){uint16_t mask=keys;for(GCController *c in GCController.controllers){GCExtendedGamepad *g=c.extendedGamepad;if(!g)continue;GCControllerButtonInput *buttons[]={g.dpad.up,g.dpad.down,g.dpad.left,g.dpad.right,g.buttonA,g.buttonB,g.buttonX,g.buttonY,g.leftShoulder,g.rightShoulder,g.buttonMenu,g.buttonOptions};for(unsigned i=0;i<12;i++)if(buttons[i].pressed)mask|=1<<i;break;}return mask;}
static NSBitmapImageRep *bitmap(const Bytes &pixels,unsigned w,unsigned h){
 NSBitmapImageRep *b=[[NSBitmapImageRep alloc]initWithBitmapDataPlanes:nil pixelsWide:w pixelsHigh:h bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:w*3 bitsPerPixel:24];
 // Cache this once: bitmapData is an AppKit accessor, not a plain field.
 // Calling it for every channel cost ~10 million Objective-C calls/second.
 auto *destination=b.bitmapData;
 for(unsigned i=0;i<w*h;i++){uint16_t v=pixels[i*2]|(pixels[i*2+1]<<8);destination[i*3]=((v>>11)&31)*255/31;destination[i*3+1]=((v>>5)&63)*255/63;destination[i*3+2]=(v&31)*255/31;}return b;
}
struct Peer{bool connected=false,authenticated=false;std::string role,key;Clock::time_point born=Clock::now();};
static ISteamNetworkingSockets *net=nullptr;static HSteamListenSocket listener=0;static HSteamNetConnection server=0,guest=0;static bool host=false,running=false,failed=false;static std::map<HSteamNetConnection,Peer> peers;
static void connection(SteamNetConnectionStatusChangedCallback_t *e){
 if(e->m_info.m_eState==k_ESteamNetworkingConnectionState_Connecting && host){if(peers.size()>=20){net->CloseConnection(e->m_hConn,0,"capacity",false);return;}peers[e->m_hConn]={};net->AcceptConnection(e->m_hConn);}
 if(e->m_info.m_eState==k_ESteamNetworkingConnectionState_Connected)peers[e->m_hConn].connected=true;
 if(e->m_info.m_eState==k_ESteamNetworkingConnectionState_ClosedByPeer || e->m_info.m_eState==k_ESteamNetworkingConnectionState_ProblemDetectedLocally){if(e->m_hConn==guest || (!host && e->m_hConn==server))failed=true;connectionFailure=e->m_info.m_eEndReason==k_ESteamNetConnectionEnd_Misc_P2P_Rendezvous?"Could not establish a connection. Check the lobby and direct/relay service, then try again.":"The other player disconnected or the network connection was lost.";net->CloseConnection(e->m_hConn,0,"closed",false);peers.erase(e->m_hConn);}
}
static bool send(HSteamNetConnection c,uint8_t type,const Bytes &payload={},bool reliable=true){Bytes b{type};b.insert(b.end(),payload.begin(),payload.end());return net->SendMessageToConnection(c,b.data(),uint32_t(b.size()),reliable?k_nSteamNetworkingSend_ReliableNoNagle:k_nSteamNetworkingSend_UnreliableNoDelay,nullptr)==k_EResultOK;}
static void mustSend(HSteamNetConnection c,uint8_t t,const Bytes &b={}){if(!send(c,t,b))throw std::runtime_error("Player transport queue full");}
static std::string localAddress(){if(config[@"address"])return str(config[@"address"]);ifaddrs *all=nullptr;getifaddrs(&all);std::string result;for(auto p=all;p;p=p->ifa_next){if(!p->ifa_addr || p->ifa_addr->sa_family!=AF_INET)continue;auto a=(sockaddr_in*)p->ifa_addr;auto n=ntohl(a->sin_addr.s_addr);if((n>>24)==10 || (n>>16)==0xc0a8 || (n>>20)==0xac1){char buf[INET_ADDRSTRLEN];inet_ntop(AF_INET,&a->sin_addr,buf,sizeof(buf));result=buf;break;}}freeifaddrs(all);if(result.empty())result="127.0.0.1";return result;}
// The lobby never blocks the emulation owner. Only its immutable result crosses
// this mailbox; errors stop the session at a frame boundary.
class LobbyWorker {
 std::mutex mutex;std::condition_variable wake;bool stopping=false;
 NSDictionary *__strong latest;std::string error;std::thread worker;
public:
 explicit LobbyWorker(NSDictionary *initial):latest(initial),worker([this]{
  auto heartbeat=Clock::now()+std::chrono::seconds(15);LobbyRetry retry;auto interval=std::chrono::milliseconds(4000);
  std::unique_lock<std::mutex> lock(mutex);
  while(!wake.wait_for(lock,interval,[this]{return stopping;})){
   lock.unlock();@autoreleasepool{try{
    retry.begin(Clock::now());
    if(!retry.canAttempt(Clock::now()))throw std::runtime_error("Lobby retry deadline exceeded");
    // Renew the lease first when due, even if the previous session read failed.
    if(Clock::now()>=heartbeat){api(@"heartbeat",@"POST",@{});heartbeat=Clock::now()+std::chrono::seconds(15);}
    if(!retry.canAttempt(Clock::now()))throw std::runtime_error("Lobby retry deadline exceeded");
    NSDictionary *result=api(@"session",@"GET");lock.lock();latest=result;retry.succeeded();lobbyRetrying=false;interval=std::chrono::milliseconds(4000);
   }catch(const LobbyHTTPError &e){lock.lock();if(!retry.failed(e.status,Clock::now())){error=e.what();return;}++lobbyTransientRetries;lobbyRetrying=true;interval=retry.delay();}
    catch(const std::exception &e){lock.lock();error=e.what();return;}}
  }
 }){}
 void stop(){{std::lock_guard<std::mutex> lock(mutex);stopping=true;}wake.notify_one();}
 ~LobbyWorker(){stop();if(worker.joinable())worker.join();}
 NSDictionary *read(){std::lock_guard<std::mutex> lock(mutex);if(!error.empty())throw std::runtime_error(error);return latest;}
};
// One encoder consumes the newest frame. Replacing a queued frame is deliberate:
// watcher throughput cannot add work to the deterministic input schedule.
class VideoEncoder {
 struct Job{Bytes pixels,audio;std::array<Bytes,SpectatorHistory> previous;unsigned width,height,frame;std::vector<HSteamNetConnection> watchers;};
 std::mutex mutex;std::condition_variable wake;std::unique_ptr<Job> latest;bool stopping=false;uint64_t encoded=0,replaced=0,totalNS=0,maxNS=0,compressedFrames=0,compressedTotal=0,compressedMax=0,messageTotal=0,queueSkipped=0,sendFailures=0,statusFailures=0,compressionFailures=0,oversizeFrames=0;std::thread worker;
public:
 VideoEncoder():worker([this]{std::unique_lock<std::mutex> lock(mutex);for(;;){
  wake.wait(lock,[this]{return stopping || latest!=nullptr;});if(stopping)return;
  auto job=std::move(latest);lock.unlock();auto encodeStart=Clock::now();
  uint64_t jobCompressed=0,jobMessage=0,jobSkipped=0,jobFailures=0,jobStatusFailures=0,jobCompressionFailures=0,jobOversize=0;
  try{
   StreamBundle bundle{job->frame,job->width,job->height,std::move(job->pixels),std::move(job->audio),std::move(job->previous)};
   Bytes b=encodeStream(bundle);
   if(b.empty())jobOversize=1;
   else{jobCompressed=b.size()-StreamHeaderBytes;jobMessage=b.size()+1;
    for(auto c:job->watchers){SteamNetConnectionRealTimeStatus_t status{};
     if(net->GetConnectionRealTimeStatus(c,&status,0,nullptr)!=k_EResultOK){++jobStatusFailures;continue;}
     if(status.m_cbPendingUnreliable>=256*1024){++jobSkipped;continue;}
     if(!send(c,8,b,false))++jobFailures;
    }
   }
  }catch(const std::exception &){++jobCompressionFailures;}
  auto elapsed=std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now()-encodeStart).count();
  lock.lock();++encoded;totalNS+=elapsed;maxNS=std::max(maxNS,uint64_t(elapsed));
  if(jobMessage){++compressedFrames;compressedTotal+=jobCompressed;compressedMax=std::max(compressedMax,jobCompressed);messageTotal+=jobMessage;}
  queueSkipped+=jobSkipped;sendFailures+=jobFailures;statusFailures+=jobStatusFailures;compressionFailures+=jobCompressionFailures;oversizeFrames+=jobOversize;
 }}){}
 ~VideoEncoder(){{std::lock_guard<std::mutex> lock(mutex);stopping=true;}wake.notify_one();if(worker.joinable())worker.join();}
 NSDictionary *metrics(){std::lock_guard<std::mutex> lock(mutex);return @{@"encoded_frames":@(encoded),@"replaced_stale_frames":@(replaced),@"average_encode_ms":@(encoded?totalNS/1e6/encoded:0),@"maximum_encode_ms":@(maxNS/1e6),@"compressed_frames":@(compressedFrames),@"compressed_total_bytes":@(compressedTotal),@"compressed_max_bytes":@(compressedMax),@"message_total_bytes":@(messageTotal),@"average_message_bytes":@(compressedFrames?double(messageTotal)/compressedFrames:0),@"estimated_60fps_bytes_per_second":@(compressedFrames?double(messageTotal)*60/compressedFrames:0),@"watcher_queue_skips":@(queueSkipped),@"send_failures":@(sendFailures),@"status_failures":@(statusFailures),@"compression_failures":@(compressionFailures),@"oversize_frames":@(oversizeFrames)};}
 void submit(const Bytes &pixels,const Bytes &audio,const std::array<Bytes,SpectatorHistory> &previous,unsigned w,unsigned h,unsigned frame,const std::vector<HSteamNetConnection> &watchers){
  if(watchers.empty())return;auto job=std::make_unique<Job>(Job{pixels,audio,previous,w,h,frame,watchers});
  {std::lock_guard<std::mutex> lock(mutex);if(latest)++replaced;latest=std::move(job);}wake.notify_one();
 }
};
int runSession(){@autoreleasepool{

 std::unique_ptr<SignalWorker> signalWorker;std::shared_ptr<SignalMailbox> signals;
 std::unique_ptr<LobbyWorker> lobbyWorker;std::unique_ptr<VideoEncoder> encoder;std::unique_ptr<SaveWriter> saveWriter;
 emu_runtime *core=nullptr;bool launched=false;std::string reportPath;unsigned completed=0,received=0;std::string lastHash,lastVideo;Bytes lastPixels,pendingAudio;std::array<Bytes,SpectatorHistory> audioHistory;unsigned lastW=0,lastH=0;uint64_t receivedAudioSamples=0,audioGaps=0;std::string lastAudio;
 try{
  for(NSString *key in @[@"endpoint",@"room_id",@"token",@"rom"])if(![config[key] isKindOfClass:NSString.class])throw std::runtime_error("Missing launch setting");
  validateLobbyOrigin();
  reportPath=str(config[@"report"]);bool headless=[config[@"headless"] boolValue];unsigned maxFrames=[config[@"frames"] unsignedIntValue];
  NSURLSessionConfiguration *hc=NSURLSessionConfiguration.ephemeralSessionConfiguration;hc.URLCache=nil;hc.HTTPCookieStorage=nil;hc.URLCredentialStorage=nil;
  http=[NSURLSession sessionWithConfiguration:hc delegate:[NoRedirect new] delegateQueue:nil];
  NSDictionary *admission=api(@"session",@"GET");std::string role=str(admission[@"room"][@"role"]);host=role=="host";bool watcher=role=="spectator";playback.setWatcher(watcher);
  bool useRollback=!config[@"rollback"] || [config[@"rollback"] boolValue];rollbackPlayer=useRollback && !watcher;if(rollbackPlayer)playback.setRollbackPlayer();
  Bytes rom=readFile(str(config[@"rom"]));check(emu_create(EMU_RUNTIME_ABI,rom.data(),uint32_t(rom.size()),&core));uint32_t stateSize;check(emu_state_size(core,&stateSize));Bytes state(stateSize);
  auto stateHash=[&](){check(emu_state_copy(core,state.data(),stateSize));return hash(state);};
  Dl_info loaded{};if(!dladdr((void*)&emu_create,&loaded))throw std::runtime_error("Runtime not loaded");
  NSDictionary *compat=@{@"protocol":@1,@"profile":ns(emu_runtime_profile()),@"rom_sha256":ns(hash(rom)),@"runtime_sha256":ns(hash(readFile(loaded.dli_fname))),@"initial_state_sha256":ns(stateHash())};
  if(![compat isEqual:admission[@"room"][@"compatibility"]])throw std::runtime_error("Game or runtime changed since joining the lobby");
  SaveIdentity saveIdentity{str(compat[@"profile"]),saveDigestFromHex(str(compat[@"rom_sha256"])),saveDigestFromHex(str(compat[@"runtime_sha256"])),saveDigestFromHex(str(compat[@"initial_state_sha256"]))};
  SaveJournal journal;journal.identity=saveIdentity;Bytes resumeBytes;SaveTransfer resumeTransfer;
  bool replayActive=false,replayDone=true,readySent=false,guestReady=false,saveRecording=true;
  unsigned baseFrame=0,replayed=0,runIndex=0,runOffset=0;std::string resumeHash=str(compat[@"initial_state_sha256"]);
  auto preparationStarted=Clock::now();
  if(config[@"resume_path"]){if(!host || !useRollback || ![config[@"resume_path"] isKindOfClass:NSString.class])throw std::runtime_error("Only a rollback host can load a saved game");
   resumeBytes=readMultiplayerSave(str(config[@"resume_path"]));journal=SaveJournal::decode(resumeBytes,saveIdentity);baseFrame=journal.frames();resumeTotal=baseFrame;replayActive=true;replayDone=false;
  }
  if(host && config[@"autosave_path"]){if(!useRollback || ![config[@"autosave_path"] isKindOfClass:NSString.class])throw std::runtime_error("Invalid multiplayer save destination");saveWriter=std::make_unique<SaveWriter>(str(config[@"autosave_path"]));}
  Bytes saveCheckpoint=state;unsigned saveCheckpointFrame=0;
  // Declared after journal/checkpoint storage so unwinding still has access to
  // both. Only shutdown restores this trusted local snapshot; no replay output
  // is presented, and storage waits never run during normal gameplay.
  struct FinalSave {std::function<void()> action;void finish(){auto fn=std::move(action);if(fn)fn();}~FinalSave(){try{finish();}catch(...){}}};
  FinalSave finalSave{[&]{if(!saveWriter)return;
   try{
    if(saveRecording && replayDone && journal.frames()){
     check(emu_state_restore(core,saveCheckpoint.data(),uint32_t(saveCheckpoint.size())));
     journal.replayConfirmedTail(saveCheckpointFrame,[&](unsigned,uint16_t p1,uint16_t p2){emu_frame ignored{};check(emu_step(core,p1,p2,&ignored));});
     check(emu_state_copy(core,state.data(),stateSize));journal.finalState=saveDigest(state);saveWriter->submit(journal);
    }
   }catch(const std::exception &e){std::lock_guard<std::mutex> lock(saveStatusMutex);saveError=e.what();}
   try{saveWriter->flush();saveCompletedFrame=saveWriter->completedFrames();auto issue=saveWriter->error();
    if(!issue.empty()){std::lock_guard<std::mutex> lock(saveStatusMutex);saveError=issue;}
   }catch(const std::exception &e){std::lock_guard<std::mutex> lock(saveStatusMutex);saveError=e.what();}
  }};
  SteamNetworkingIdentity localIdentity;localIdentity.Clear();
  if(admission[@"identity"] && !localIdentity.ParseString([admission[@"identity"] UTF8String]))throw std::runtime_error("Invalid lobby identity");
  SteamDatagramErrMsg err;if(!GameNetworkingSockets_Init(localIdentity.IsInvalid()?nullptr:&localIdentity,err))throw std::runtime_error(err);net=SteamNetworkingSockets();
  SteamNetworkingConfigValue_t opt[7];opt[0].SetPtr(k_ESteamNetworkingConfig_Callback_ConnectionStatusChanged,(void*)&connection);opt[1].SetInt32(k_ESteamNetworkingConfig_IP_AllowWithoutAuth,2);opt[2].SetInt32(k_ESteamNetworkingConfig_SendBufferSize,1024*1024);opt[3].SetInt32(k_ESteamNetworkingConfig_RecvBufferSize,2*1024*1024);opt[4].SetInt32(k_ESteamNetworkingConfig_RecvBufferMessages,256);opt[5].SetInt32(k_ESteamNetworkingConfig_RecvMaxMessageSize,300000);opt[6].SetInt32(k_ESteamNetworkingConfig_TimeoutConnected,5000);
  bool requestICE=config[@"connection"]!=nil;
  std::string preference=config[@"connection"]?str(config[@"connection"]):"automatic";
  if(preference!="automatic" && preference!="direct" && preference!="relay")throw std::runtime_error("Invalid connection preference");
  if(headless && config[@"test_network"]){
   NSDictionary *test=config[@"test_network"];double lag=[test[@"lag_ms"] doubleValue],loss=[test[@"loss_percent"] doubleValue];
   if(lag<0 || lag>250 || loss<0 || loss>10)throw std::runtime_error("Invalid network test settings");
   SteamNetworkingUtils()->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_FakePacketLag_Send,int(lag));
   SteamNetworkingUtils()->SetGlobalConfigValueFloat(k_ESteamNetworkingConfig_FakePacketLoss_Send,float(loss));
  }
  if(host && requestICE){api(@"launch",@"POST",@{@"transport":@"ice",@"route":ns(preference),@"delay":config[@"delay"]?:@3});launched=true;}
  if(host && !requestICE){SteamNetworkingIPAddr address;address.Clear();for(int attempt=0;attempt<8 && !listener;attempt++){address.m_port=49152+arc4random_uniform(16384);listener=net->CreateListenSocketIP(address,7,opt);}if(!listener || !net->GetListenSocketAddress(listener,&address))throw std::runtime_error("Cannot listen for players");api(@"launch",@"POST",@{@"address":ns(localAddress()),@"port":@(address.m_port),@"delay":config[@"delay"]?:@3});launched=true;}
  // Waiting for the host is still an active membership. Renew before waiting
  // and every 15 seconds; otherwise a late start races the 60-second lease.
  // One session poll/second also stays below the lobby request budget.
  api(@"heartbeat",@"POST",@{});
  auto waitStart=Clock::now(),waitHeartbeat=waitStart+std::chrono::seconds(15);NSDictionary *session=nil;
  while(!(session=admission[@"session"]) || session==(id)NSNull.null){
   if(closeRequested())throw std::runtime_error("Game window closed while waiting for host");
   if(Clock::now()-waitStart>std::chrono::minutes(10))throw std::runtime_error("Host has not started this game");
   if(Clock::now()>=waitHeartbeat){api(@"heartbeat",@"POST",@{});waitHeartbeat=Clock::now()+std::chrono::seconds(15);}
   std::this_thread::sleep_for(std::chrono::seconds(1));admission=api(@"session",@"GET");
  }
  std::string sessionID=str(session[@"id"]),playKey=str(admission[@"play_key"]),hostKey=str(admission[@"host_key"]);unsigned delay=[session[@"delay"] unsignedIntValue];Lockstep schedule(delay);inputDelayMS=useRollback?0:delay*16.639;
  std::map<unsigned,Clock::time_point> inputSampleTimes;
  bool ice=[session[@"transport"] isEqual:@"ice"];
  if(ice){
   std::string route=str(session[@"route"]);if(preference=="direct" && route=="relay")throw std::runtime_error("This room requires relay; select Automatic or Relay only");if(preference=="relay")route="relay";else if(preference=="direct" && route!="relay")route="direct";
   NSDictionary *settings=connectionSettings(admission,route!="direct",route=="relay");NSArray *stun=settings[@"stun_servers"],*turn=settings[@"turn_servers"];
   if(route=="relay" && !turn.count)throw std::runtime_error("Relay service is not configured for this lobby");
   auto utils=SteamNetworkingUtils();
   utils->SetGlobalConfigValuePtr(k_ESteamNetworkingConfig_Callback_ConnectionStatusChanged,(void*)&connection);
   utils->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_P2P_Transport_ICE_Implementation,1);
   utils->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_P2P_Transport_ICE_Enable,route=="relay"?1:(route=="direct" || !turn.count)?6:7);
   utils->SetGlobalConfigValueString(k_ESteamNetworkingConfig_P2P_STUN_ServerList,[[stun componentsJoinedByString:@","] UTF8String]);
   utils->SetGlobalConfigValueString(k_ESteamNetworkingConfig_P2P_TURN_ServerList,route=="direct"?"" : [[turn componentsJoinedByString:@","] UTF8String]);
   if(turn.count && route!="direct"){
    if([settings[@"turn_expires_at"] isKindOfClass:NSNumber.class])installedTURNExpiresAt=[settings[@"turn_expires_at"] longLongValue];
    if(![settings[@"turn_username"] isKindOfClass:NSString.class] || ![settings[@"turn_password"] isKindOfClass:NSString.class])throw std::runtime_error("Missing relay credentials");
    NSMutableArray *users=[NSMutableArray array],*passwords=[NSMutableArray array];for(NSUInteger i=0;i<turn.count;i++){[users addObject:settings[@"turn_username"]];[passwords addObject:settings[@"turn_password"]];}
    utils->SetGlobalConfigValueString(k_ESteamNetworkingConfig_P2P_TURN_UserList,[[users componentsJoinedByString:@","] UTF8String]);
    utils->SetGlobalConfigValueString(k_ESteamNetworkingConfig_P2P_TURN_PassList,[[passwords componentsJoinedByString:@","] UTF8String]);
   }
   signals=std::make_shared<SignalMailbox>();signalWorker=std::make_unique<SignalWorker>(signals,sessionID,[admission[@"signaling_request_ids"] isEqual:@YES]);
   if(host){listener=net->CreateListenSocketP2P(0,7,opt);if(!listener)throw std::runtime_error("Cannot create P2P listener");}
   else{SteamNetworkingIdentity remote;remote.Clear();if(!remote.ParseString([admission[@"host_identity"] UTF8String]))throw std::runtime_error("Invalid host identity");server=net->ConnectP2PCustomSignaling(new LobbySignaler(signals,str(admission[@"host_identity"])),&remote,0,7,opt);if(!server)throw std::runtime_error("Cannot start ICE connection");peers[server]={};}
  }else if(!host){
   if(preference=="relay")throw std::runtime_error("This room uses LAN transport; relay-only cannot join");
   SteamNetworkingIPAddr address;address.Clear();std::string endpoint=str(session[@"address"])+":"+std::to_string([session[@"port"] unsignedIntValue]);if(!address.ParseString(endpoint.c_str()))throw std::runtime_error("Invalid host address");server=net->ConnectByIPAddress(address,7,opt);if(!server)throw std::runtime_error("Cannot connect to host");peers[server]={};
  }
  lobbyWorker=std::make_unique<LobbyWorker>(admission);
  if(host)encoder=std::make_unique<VideoEncoder>();
  std::ofstream traceLog;if(!reportPath.empty())traceLog.open(reportPath+".hashes");
  std::vector<std::array<uint16_t,2>> trace;if(config[@"trace"]){std::ifstream f(str(config[@"trace"]));unsigned n,a,b;while(f>>n>>a>>b){if(n!=trace.size()+1 || a>4095 || b>4095)throw std::runtime_error("Invalid test trace");trace.push_back({uint16_t(a),uint16_t(b)});}}
  std::map<unsigned,std::string> localHashes,remoteHashes;auto compare=[&](){for(auto it=remoteHashes.begin();it!=remoteHashes.end();){auto own=localHashes.find(it->first);if(own==localHashes.end()){++it;continue;}if(own->second!=it->second)throw std::runtime_error("State mismatch at frame "+std::to_string(it->first));localHashes.erase(own);it=remoteHashes.erase(it);}if(localHashes.size()>10 || remoteHashes.size()>10)throw std::runtime_error("State verification timed out");};
  emu_frame rollbackOutput{};RollbackAudio correctedAudio;std::vector<int16_t> audible;
  auto checkpoint=[&](unsigned f,const Bytes &snapshot){if(host && saveRecording && saveWriter){saveCheckpoint=snapshot;saveCheckpointFrame=baseFrame+f;journal.finalState=saveDigest(snapshot);saveWriter->submit(journal);}lastHash=hash(snapshot);localHashes[f]=lastHash;Bytes b;append(b,f,4);b.insert(b.end(),lastHash.begin(),lastHash.end());mustSend(host?guest:server,4,b);compare();if(traceLog)traceLog<<f<<" state "<<lastHash<<"\n";};
  Rollback rollback(host?0:1,[&](){Bytes saved(stateSize);check(emu_state_copy(core,saved.data(),stateSize));return saved;},
   [&](const Bytes &saved){check(emu_state_restore(core,saved.data(),uint32_t(saved.size())));correctedAudio.corrected();},
   [&](unsigned,uint16_t p1,uint16_t p2,bool replay){emu_frame output{};check(emu_step(core,p1,p2,&output));if(!replay)rollbackOutput=output;},checkpoint,
   [&](unsigned f,uint16_t p1,uint16_t p2){if(host && saveRecording){try{journal.append(baseFrame+f,p1,p2);}catch(const std::exception &e){saveRecording=false;std::lock_guard<std::mutex> lock(saveStatusMutex);saveError=e.what();}}});
  InputTransport inputTransport;uint64_t inputPackets=0,inputSendDrops=0;auto lastInputSend=Clock::time_point{};
  auto sendInputs=[&](){if(!send(host?guest:server,3,inputTransport.packet(),false))++inputSendDrops;++inputPackets;lastInputSend=Clock::now();};
  auto nextFrame=[&](){return useRollback?rollback.next():schedule.next();};
  auto inputsReady=[&](){return useRollback?rollback.ready():schedule.ready();};
  auto finished=[&](){return !useRollback || watcher || (rollback.confirmed()>=maxFrames && inputTransport.drained());};
  auto telemetryTime=Clock::now();
  auto progress=Clock::now(),pace=progress;unsigned sampled=0;uint16_t sampledMask=0;bool hello=false;auto endWait=Clock::time_point{};auto firstStep=Clock::time_point{},lastStep=firstStep,waitingSince=firstStep;uint64_t coreNS=0,maxCoreNS=0,networkWaitNS=0;unsigned pacingResets=0;
  preparationStarted=Clock::now();
  while(!closeRequested()){@autoreleasepool{
   auto now=Clock::now();if(maxFrames && completed>=maxFrames && (watcher || (finished() && localHashes.empty() && remoteHashes.empty())) && (failed || (endWait!=Clock::time_point{} && now-endWait>std::chrono::seconds(1))))break;if(failed)throw std::runtime_error(connectionFailure.empty()?"Player disconnected; game stopped":connectionFailure);
   // Once a finite validation run has verified its final checkpoint, drain
   // GNS without racing a peer's lobby teardown. Live sessions keep polling.
   bool verifiedEnd=maxFrames && completed>=maxFrames && (watcher || (finished() && localHashes.empty() && remoteHashes.empty()));
   if(verifiedEnd){if(endWait==Clock::time_point{})endWait=now;
    // Request stop without joining HTTP workers on the simulation owner.
    // Their destructors join only after the final GNS/ACK drain loop exits.
    if(signalWorker)signalWorker->stop();if(lobbyWorker)lobbyWorker->stop();}
   else{endWait=Clock::time_point{};
    admission=lobbyWorker->read();
    if(admission[@"session"]==(id)NSNull.null || ![admission[@"session"][@"id"] isEqual:ns(sessionID)])throw std::runtime_error("Host ended the game");
    if(signalWorker)signalWorker->poll(net,host);
   }
   net->RunCallbacks();std::vector<HSteamNetConnection> connections;for(auto &[c,p]:peers)connections.push_back(c);
   for(auto c:connections){auto it=peers.find(c);if(it==peers.end())continue;Peer &peer=it->second;
    if(host && peer.authenticated){bool allowed=false;for(NSDictionary *p in admission[@"peers"])if(str(p[@"key"])==peer.key && str(p[@"role"])==peer.role)allowed=true;if(!allowed){if(c==guest)throw std::runtime_error("Player membership expired");net->CloseConnection(c,0,"membership ended",false);peers.erase(c);continue;}}
    if(!peer.authenticated && now-peer.born>std::chrono::seconds(ice?30:10)){if(!host)throw std::runtime_error("Handshake timed out");net->CloseConnection(c,0,"timeout",false);peers.erase(c);continue;}
    for(int m=0;m<64;m++){SteamNetworkingMessage_t *msg=nullptr;int count=net->ReceiveMessagesOnConnection(c,&msg,1);if(count<0)break;if(!count)break;Bytes b((uint8_t*)msg->m_pData,(uint8_t*)msg->m_pData+msg->m_cbSize);msg->Release();
     try{
      if(b.empty() || b.size()>300000)throw std::runtime_error("Invalid packet size");unsigned type=b[0];Bytes payload(b.begin()+1,b.end());
      if(type==1 && host && !peer.authenticated){NSDictionary *h=object(payload);if(![h[@"stream_version"] isEqual:@8] || ![h[@"session"] isEqual:ns(sessionID)] || ![h[@"compatibility"] isEqual:compat])throw std::runtime_error("Incompatible peer");std::string key=str(h[@"key"]),claimed=str(h[@"role"]);if(claimed=="guest" && ![h[@"netcode"] isEqual:useRollback?@"rollback-v3":@"delay-v2"])throw std::runtime_error("Player netcode differs; update both Macs");bool allowed=false;for(NSDictionary *p in admission[@"peers"])if(str(p[@"key"])==key && str(p[@"role"])==claimed)allowed=true;
       if(!allowed || (claimed!="guest" && claimed!="spectator"))throw std::runtime_error("Unadmitted peer");for(auto &[other,p]:peers)if(other!=c && p.authenticated && p.key==key)throw std::runtime_error("Duplicate peer");
       if(claimed=="guest" && (guest || running))throw std::runtime_error("Player slot occupied");peer.key=key;peer.role=claimed;peer.authenticated=true;if(claimed=="guest")guest=c;
       // GNS defaults to 256 KiB/s; compressed LAN video plus stereo PCM
       // exceeds that. Current PCM plus twelve history blocks uses about 28 KiB/frame.
       // 4 MiB/s permits about 68 KiB/frame at 60 Hz, leaving video/packet headroom.
       // Keep the 256 KiB queue bound so a slow watcher cannot accumulate latency.
       // Player connections retain their independent input/control budget.
       if(claimed=="spectator"){SteamNetworkingUtils()->SetConnectionConfigValueInt32(c,k_ESteamNetworkingConfig_SendRateMin,4*1024*1024);SteamNetworkingUtils()->SetConnectionConfigValueInt32(c,k_ESteamNetworkingConfig_SendRateMax,4*1024*1024);}
       mustSend(c,2,json(@{@"key":ns(hostKey),@"session":ns(sessionID),@"compatibility":compat,@"stream_version":@8,@"netcode":useRollback?@"rollback-v3":@"delay-v2",@"resume_bytes":@(resumeBytes.size()),@"resume_frames":@(baseFrame),@"resume_sha256":resumeBytes.empty()?@"":ns(saveDigestHex(saveDigest(resumeBytes)))}));continue;
      }
      if(type==2 && !host && !peer.authenticated){NSDictionary *h=object(payload);if(![h[@"stream_version"] isEqual:@8] || ![h[@"key"] isEqual:ns(hostKey)] || ![h[@"session"] isEqual:ns(sessionID)] || ![h[@"compatibility"] isEqual:compat])throw std::runtime_error("Host verification failed");if(!watcher && ![h[@"netcode"] isEqual:useRollback?@"rollback-v3":@"delay-v2"])throw std::runtime_error("Player netcode differs; update both Macs");peer.authenticated=true;
       if(!watcher){
        if(![h[@"resume_bytes"] isKindOfClass:NSNumber.class] || ![h[@"resume_frames"] isKindOfClass:NSNumber.class] || ![h[@"resume_sha256"] isKindOfClass:NSString.class])throw std::runtime_error("Invalid saved-game offer");
        auto count=[h[@"resume_bytes"] unsignedLongLongValue],frames=[h[@"resume_frames"] unsignedLongLongValue];
        if(count>SaveJournal::MaxBytes || frames>SaveJournal::MaxFrames || bool(count)!=bool(frames) || (!count && [h[@"resume_sha256"] length]))throw std::runtime_error("Invalid saved-game offer bounds");
        if(count){resumeTransfer.begin(size_t(count),saveDigestFromHex(str(h[@"resume_sha256"])));resumeTotal=unsigned(frames);replayDone=false;Bytes request;append(request,0,4);mustSend(c,10,request);}
        else{Bytes ready(resumeHash.begin(),resumeHash.end());mustSend(c,6,ready);readySent=true;}
       }else running=true;progress=Clock::now();continue;}
      if(!peer.authenticated)throw std::runtime_error("Message before admission");
      // Only the authenticated player can request journal chunks, and only
      // the authenticated host can supply them. One request in flight bounds
      // queued reliable data; remote bytes are never passed to state_restore.
      if(type==10 && host && c==guest && !running && !resumeBytes.empty()){
       Reader request{payload};size_t offset=size_t(request.get(4));request.end();if(offset>=resumeBytes.size() || offset%SaveTransfer::chunkSize())throw std::runtime_error("Invalid saved-game chunk request");
       size_t count=std::min(SaveTransfer::chunkSize(),resumeBytes.size()-offset);Bytes chunk;append(chunk,offset,4);chunk.insert(chunk.end(),resumeBytes.begin()+offset,resumeBytes.begin()+offset+count);mustSend(c,11,chunk);progress=Clock::now();continue;
      }
      if(type==11 && !host && !watcher && c==server && !running && !replayActive && !replayDone){
       Reader chunk{payload};size_t offset=size_t(chunk.get(4));Bytes bytes(payload.begin()+chunk.pos,payload.end());resumeTransfer.put(offset,bytes);
       if(resumeTransfer.complete()){journal=SaveJournal::decode(resumeTransfer.finish(),saveIdentity);if(journal.frames()!=resumeTotal)throw std::runtime_error("Saved-game frame count differs from offer");baseFrame=journal.frames();replayActive=true;}
       else{Bytes request;append(request,resumeTransfer.received(),4);mustSend(c,10,request);}progress=Clock::now();continue;
      }
      if(type==6 && host && c==guest && !running){
       std::string expected=baseFrame?saveDigestHex(journal.finalState):str(compat[@"initial_state_sha256"]);
       if(payload.size()!=64 || std::string(payload.begin(),payload.end())!=expected)throw std::runtime_error("Player restored a different saved-game state");guestReady=true;progress=Clock::now();continue;
      }
      if(type==7 && !host && !watcher && !running){if(!replayDone || !readySent || payload.size()!=64 || std::string(payload.begin(),payload.end())!=resumeHash)throw std::runtime_error("Invalid restored start state");running=true;progress=pace=Clock::now();continue;}
      if(type==3 && !watcher && (running || useRollback) && (host?c==guest:c==server)){
       // An unreliable input may overtake reliable START. Authentication and
       // the bounded input window are enough to buffer it before simulation.
       if(useRollback){for(auto [f,mask]:inputTransport.receive(payload,nextFrame()))rollback.putRemote(f,mask);}
       else{Reader r{payload};unsigned f=r.get(4);uint16_t mask=r.get(2);r.end();if(f<=delay)throw std::runtime_error("Invalid input frame");schedule.put(host?1:0,f,mask);}continue;}
      if(type==4 && !watcher && running && (host?c==guest:c==server)){Reader r{payload};unsigned f=r.get(4);if(!f || f%60 || f>nextFrame()+120 || f+120<nextFrame() || payload.size()!=68)throw std::runtime_error("Invalid state checkpoint");std::string h(payload.begin()+4,payload.end());if(remoteHashes.count(f) && remoteHashes[f]!=h)throw std::runtime_error("Conflicting checkpoint");remoteHashes[f]=h;compare();continue;}
      if(type==8 && watcher && c==server){auto bundle=decodeStream(payload);unsigned f=bundle.frame,w=bundle.width,h=bundle.height;
       if(f>completed){uint64_t recovered=0,missing=0;Bytes audible=streamAudio(bundle,completed,recovered,missing);recoveredAudio+=recovered;unrecoveredAudio+=missing;bool gap=completed==0 || f!=completed+1;if(completed && gap){++audioGaps;++streamGaps;}++streamFrames;completed=f;lastVideo=hash(bundle.pixels);lastAudio=hash(bundle.audio);receivedAudioSamples+=bundle.audio.size()/4;
        lastPixels=std::move(bundle.pixels);lastW=w;lastH=h;received++;progress=Clock::now();if(firstStep==Clock::time_point{})firstStep=progress;else sessionFPS=(received-1)/std::chrono::duration<double>(progress-firstStep).count();
        std::vector<int16_t> pcm(audible.size()/2);for(size_t i=0;i<pcm.size();i++)pcm[i]=int16_t(uint16_t(audible[2*i])|(uint16_t(audible[2*i+1])<<8));emu_frame sound{};sound.audio=pcm.data();sound.audio_frames=pcm.size()/2;
        presentFrame(lastPixels,lastW,lastH,completed,role,&sound,bundle.audio.size()/4);if(traceLog)traceLog<<f<<" video "<<lastVideo<<"\n"<<f<<" audio "<<lastAudio<<"\n";
       }continue;}

      throw std::runtime_error("Role cannot send this message");
     }catch(const std::exception&){if(!host || c==guest)throw;net->CloseConnection(c,0,"invalid watcher",false);peers.erase(c);break;}
    }
   }
   if(!host && !hello && peers.count(server) && peers[server].connected && now-peers[server].born>std::chrono::seconds(5)){mustSend(server,1,json(@{@"key":ns(playKey),@"role":ns(role),@"session":ns(sessionID),@"compatibility":compat,@"stream_version":@8,@"netcode":useRollback?@"rollback-v3":@"delay-v2"}));hello=true;}
   // Rebuild saved state in small slices on the sole emulator owner. HTTP
   // workers keep leases alive and GNS callbacks are serviced between slices.
   // Replayed output never enters the player or spectator presentation queues.
   if(replayActive){
    auto deadline=Clock::now()+std::chrono::milliseconds(2);
    do{const auto &entry=journal.runs().at(runIndex);emu_frame ignored{};check(emu_step(core,entry.player1,entry.player2,&ignored));++replayed;++runOffset;
     if(runOffset==entry.frames){++runIndex;runOffset=0;}resumeFrame=replayed;
    }while(replayed<journal.frames() && Clock::now()<deadline && !closeRequested());
    progress=Clock::now();
    if(replayed==journal.frames()){check(emu_state_copy(core,state.data(),stateSize));journal.verifyFinal(saveDigest(state));resumeHash=hash(state);replayActive=false;replayDone=true;
     if(host && saveWriter){saveCheckpoint=state;saveCheckpointFrame=baseFrame;saveWriter->submit(journal);}
     if(!host){Bytes ready(resumeHash.begin(),resumeHash.end());mustSend(server,6,ready);readySent=true;}
    }
   }
   if(host && guestReady && replayDone && !running){SteamNetConnectionRealTimeStatus_t startStats{};int rtt=net->GetConnectionRealTimeStatus(guest,&startStats,0,nullptr)==k_EResultOK?startStats.m_nPing:-1;
    Bytes start(resumeHash.begin(),resumeHash.end());mustSend(guest,7,start);running=true;progress=Clock::now();auto offset=hostStartOffset(rtt);hostStartOffsetMS=offset.count()/1000.0;pace=progress+offset;
   }
   if(!running && Clock::now()-preparationStarted>std::chrono::minutes(10))throw std::runtime_error("Saved-game/session preparation timed out");
   if(!watcher && running && useRollback){rollback.reconcile();rollbackCount=rollback.rollbackCount;rollbackFrames=rollback.replayedFrames;rollbackDepth=rollback.maximumDepth;confirmedFrame=rollback.confirmed();}
   if(!watcher && running && (!maxFrames || completed<maxFrames)){
    if(!inputsReady()){if(waitingSince==Clock::time_point{})waitingSince=Clock::now();}
    else if(waitingSince!=Clock::time_point{}){networkWaitNS+=std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now()-waitingSince).count();waitingSince=Clock::time_point{};}
    unsigned frame=nextFrame();if(inputSampleDue(sampled,frame,now,pace) && (!useRollback || inputsReady())){uint16_t mask=trace.empty()?liveInput.load():trace.at(baseFrame+frame-1)[host?0:1];unsigned target=useRollback?frame:schedule.sampleFrame();inputSampleTimes[target]=Clock::now();if(!useRollback){schedule.put(host?0:1,target,mask);Bytes b;append(b,target,4);append(b,mask,2);mustSend(host?guest:server,3,b);}else{rollbackOutput={};inputTransport.sample(target,mask);sendInputs();}sampled=frame;sampledMask=mask;}
    if(inputsReady() && sampled==frame && now>=pace){auto stamp=inputSampleTimes.find(frame);if(stamp!=inputSampleTimes.end()){inputQueueMS=std::chrono::duration<double,std::milli>(Clock::now()-stamp->second).count();inputSampleTimes.erase(stamp);}std::array<uint16_t,2> input{};if(!useRollback)input=schedule.take();emu_frame output{};auto coreStart=Clock::now();if(firstStep==Clock::time_point{})firstStep=coreStart;
     if(useRollback){rollback.advance(sampledMask);output=rollbackOutput;audible=correctedAudio.forward(output.audio,output.audio_frames);output.audio=audible.data();}else check(emu_step(core,input[0],input[1],&output));completed=frame;progress=lastStep=Clock::now();
     auto elapsed=std::chrono::duration_cast<std::chrono::nanoseconds>(lastStep-coreStart).count();coreNS+=elapsed;maxCoreNS=std::max(maxCoreNS,uint64_t(elapsed));
     // Deadlines advance from the previous deadline, not from work completion.
     // After a long stall, avoid an unbounded catch-up burst.
     const auto interval=std::chrono::microseconds(16639);pace+=interval;
     if(progress-pace>interval*4){pace=progress+interval;++pacingResets;}
     if(frame>1)sessionFPS=(frame-1)/std::chrono::duration<double>(lastStep-firstStep).count();
     lastW=output.width;lastH=output.height;lastPixels.resize(lastW*lastH*2);for(unsigned y=0;y<lastH;y++)memcpy(lastPixels.data()+y*lastW*2,output.video+y*output.pitch,lastW*2);lastVideo=hash(lastPixels);
     if(!useRollback && frame%60==0){lastHash=stateHash();localHashes[frame]=lastHash;Bytes b;append(b,frame,4);b.insert(b.end(),lastHash.begin(),lastHash.end());mustSend(host?guest:server,4,b);compare();if(traceLog)traceLog<<frame<<" state "<<lastHash<<"\n";}
     if(host){for(unsigned i=0;i<output.audio_frames*2;i++)append(pendingAudio,uint16_t(output.audio[i]),2);}
     if(host){std::vector<HSteamNetConnection> watchers;for(auto &[c,p]:peers)if(p.authenticated && p.role=="spectator")watchers.push_back(c);lastAudio=hash(pendingAudio);encoder->submit(lastPixels,pendingAudio,audioHistory,lastW,lastH,frame,watchers);for(unsigned i=SpectatorHistory-1;i>0;--i)audioHistory[i]=std::move(audioHistory[i-1]);audioHistory[0]=std::move(pendingAudio);pendingAudio.clear();if(traceLog)traceLog<<frame<<" video "<<lastVideo<<"\n"<<frame<<" audio "<<lastAudio<<"\n";}
     presentFrame(lastPixels,lastW,lastH,frame,role,&output);
    }
   }
   // Continue redundant delivery and ACKs when prediction is exhausted and
   // while draining a finite run. A dropped final input/ACK cannot deadlock it.
   if(useRollback && !watcher && running && Clock::now()-lastInputSend>=std::chrono::milliseconds(16))sendInputs();
   if(Clock::now()-telemetryTime>=std::chrono::seconds(1)){
    telemetryTime=Clock::now();if(saveWriter){saveCompletedFrame=saveWriter->completedFrames();auto issue=saveWriter->error();if(!issue.empty()){std::lock_guard<std::mutex> lock(saveStatusMutex);saveError=issue;}}auto peer=host?guest:server;SteamNetConnectionInfo_t info{};SteamNetConnectionRealTimeStatus_t stats{};
    if(peer && net->GetConnectionInfo(peer,&info) && net->GetConnectionRealTimeStatus(peer,&stats,0,nullptr)==k_EResultOK){selectedRoute=(info.m_nFlags&k_nSteamNetworkConnectionInfoFlags_Relayed)?2:1;networkRTT=stats.m_nPing;networkQuality=stats.m_flConnectionQualityLocal;}
   }
   if(Clock::now()-progress>std::chrono::seconds(running && (!watcher || received)?12:600))throw std::runtime_error("No game progress; session stopped");
   std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }}
  finalSave.finish();
  std::string finalSaveError;{std::lock_guard<std::mutex> lock(saveStatusMutex);finalSaveError=saveError;}
  NSDictionary *performance=@{@"installed_turn_expires_at":@(installedTURNExpiresAt.load()),@"lobby_transient_retries":@(lobbyTransientRetries.load()),@"signal_transient_retries":@(signalTransientRetries.load()),@"lobby_reconnecting":@(lobbyRetrying.load() || signalRetrying.load()),@"save_completed_frame":@(saveCompletedFrame.load()),@"save_error":ns(finalSaveError),@"resume_frame":@(resumeFrame.load()),@"resume_total":@(resumeTotal.load()),@"netcode":useRollback?@"rollback-v3":@"delay-v2",@"confirmed_frame":@(rollback.confirmed()),@"input_packets":@(inputPackets),@"input_send_drops":@(inputSendDrops),@"input_receipt_frame":@(inputTransport.received()),@"input_acknowledged_frame":@(inputTransport.acknowledged()),@"input_duplicate_masks":@(inputTransport.duplicateInputs),@"rollback_count":@(rollback.rollbackCount),@"replayed_frames":@(rollback.replayedFrames),@"maximum_rollback_depth":@(rollback.maximumDepth),@"route":selectedRoute==2?@"relay":selectedRoute==1?@"direct":@"unknown",@"rtt_ms":@(networkRTT.load()),@"connection_quality":@(networkQuality.load()),@"simulation_fps":@(watcher?0:sessionFPS.load()),@"received_video_fps":@(watcher?sessionFPS.load():0),@"average_core_ms":@(completed?coreNS/1e6/completed:0),@"maximum_core_ms":@(maxCoreNS/1e6),@"network_wait_ms":@(networkWaitNS/1e6),@"pacing_resets":@(pacingResets),@"encoder":encoder?encoder->metrics():@{}};
  if(!reportPath.empty()){NSDictionary *r=@{@"result":@"PASS",@"performance":performance,@"role":ns(role),@"frames":@(completed),@"received_video_frames":@(received),@"received_audio_samples":@(receivedAudioSamples),@"audio_discontinuities":@(audioGaps),@"recovered_audio_frames":@(recoveredAudio.load()),@"unrecovered_audio_frames":@(unrecoveredAudio.load()),@"audio_sha256":ns(lastAudio),@"state_sha256":ns(lastHash),@"video_sha256":ns(lastVideo)};auto b=json(r);std::ofstream f(reportPath);f.write((char*)b.data(),b.size());if(!lastPixels.empty())[[bitmap(lastPixels,lastW,lastH) representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:ns(reportPath+".png") atomically:YES];}
  encoder.reset();signalWorker.reset();lobbyWorker.reset();
  if(launched){try{api(@"stop",@"POST",@{});}catch(...) {}}
  if(core)emu_destroy(core);GameNetworkingSockets_Kill();printf("{\"status\":\"Game ended\"}\n");return 0;
 }catch(const std::exception &e){encoder.reset();signalWorker.reset();lobbyWorker.reset();if(launched){try{api(@"stop",@"POST",@{});}catch(...) {}}if(core)emu_destroy(core);if(net)GameNetworkingSockets_Kill();std::string shutdownSaveError;{std::lock_guard<std::mutex> lock(saveStatusMutex);shutdownSaveError=saveError;}auto b=json(@{@"error":ns(e.what()),@"frames":@(completed),@"save_completed_frame":@(saveCompletedFrame.load()),@"save_error":ns(shutdownSaveError)});if([config[@"audio_report"] isKindOfClass:NSString.class]){std::ofstream diagnostic(str(config[@"audio_report"])+".session.json");diagnostic.write((char*)b.data(),b.size());}fwrite(b.data(),1,b.size(),stdout);puts("");if(!reportPath.empty()){std::ofstream f(reportPath);f.write((char*)b.data(),b.size());}return 1;}
}}

// AppKit and controller sampling stay on the main thread. Audio pulls from
// its ring on the device callback, independently of window event tracking.
// The entire core lifetime (including creation and destruction) stays on its
// single emulation thread. GNS owns its socket I/O thread internally.
int main(){@autoreleasepool{
 try{
  struct sigaction termination{};termination.sa_handler=requestTermination;sigemptyset(&termination.sa_mask);
  if(sigaction(SIGTERM,&termination,nullptr) || sigaction(SIGINT,&termination,nullptr))throw std::runtime_error("Cannot install clean shutdown handlers");
  std::string line;std::getline(std::cin,line);if(line.size()>16384)throw std::runtime_error("Invalid launch configuration");config=object(Bytes(line.begin(),line.end()));
  if([config[@"headless"] boolValue])return runSession();
  [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];[NSApp finishLaunching];
  NSWindow *window=[[GameWindow alloc]initWithContentRect:NSMakeRect(0,0,768,672) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];window.releasedWhenClosed=NO;window.title=@"Network Play — Connecting";
  GameView *view=[[GameView alloc]initWithFrame:window.contentView.bounds];view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;window.contentView=view;
  WindowDelegate *wd=[WindowDelegate new];window.delegate=wd;[window center];[window makeKeyAndOrderFront:nil];[window makeFirstResponder:view];[NSApp activateIgnoringOtherApps:YES];
  AVAudioEngine *audio=[AVAudioEngine new];AVAudioFormat *format=[[AVAudioFormat alloc]initStandardFormatWithSampleRate:32040 channels:2];
  mach_timebase_info_data_t timebase;mach_timebase_info(&timebase);double hostSecondsPerTick=double(timebase.numer)/timebase.denom/1e9;
  AVAudioSourceNode *source=[[AVAudioSourceNode alloc]initWithFormat:format renderBlock:^OSStatus(BOOL *silence,const AudioTimeStamp *timestamp,AVAudioFrameCount frames,AudioBufferList *buffers){
   auto first=playback.position();auto trimBefore=playback.trims.load();
   playback.pull((float*)buffers->mBuffers[0].mData,(float*)buffers->mBuffers[1].mData,frames);
   auto last=playback.position();
   // A backlog trim is a discontinuity, not accelerated playback.
   if(playback.trims.load()!=trimBefore)first=last;
   double hostTime=((timestamp->mFlags&kAudioTimeStampHostTimeValid)?timestamp->mHostTime:mach_absolute_time())*hostSecondsPerTick;
   videoClock.publish(hostTime,frames/32040.0,first,last);return noErr;
  }];
  [audio attachNode:source];[audio connect:source to:audio.mainMixerNode format:format];NSError *error=nil;BOOL audioStarted=[audio startAndReturnError:&error];
  std::atomic<bool> done{false};int result=1;
  std::thread simulation([&]{result=runSession();done=true;});unsigned displayed=0;uint64_t displayedFrames=0,skippedPictures=0;auto firstPicture=Clock::time_point{},lastPicture=firstPicture;
  uint64_t conversionNS=0,maximumConversionNS=0;auto nextReport=Clock::now()+std::chrono::seconds(5),titleTime=Clock::now();uint64_t titleDraws=0;std::string displayedRole;
  VideoPhase videoPhase;
  auto lastTick=Clock::time_point{};double maximumTickGapMS=0,videoPosition=0,refreshHz=0,audioHostLead=0;uint64_t delayedTicks=0,displayCallbacks=0,repeatedDisplayFrames=0;
  auto diagnostics=[&](){std::string saveIssue;{std::lock_guard<std::mutex> lock(saveStatusMutex);saveIssue=saveError;}NSDictionary *d=@{@"installed_turn_expires_at":@(installedTURNExpiresAt.load()),@"lobby_transient_retries":@(lobbyTransientRetries.load()),@"signal_transient_retries":@(signalTransientRetries.load()),@"lobby_reconnecting":@(lobbyRetrying.load() || signalRetrying.load()),@"save_completed_frame":@(saveCompletedFrame.load()),@"save_error":ns(saveIssue),@"resume_frame":@(resumeFrame.load()),@"resume_total":@(resumeTotal.load()),@"rollback_player":@(rollbackPlayer.load()),@"rollback_count":@(rollbackCount.load()),@"replayed_frames":@(rollbackFrames.load()),@"maximum_rollback_depth":@(rollbackDepth.load()),@"confirmed_frame":@(confirmedFrame.load()),@"configured_input_delay_ms":@(inputDelayMS.load()),@"latest_input_queue_ms":@(inputQueueMS.load()),@"host_start_offset_ms":@(hostStartOffsetMS.load()),@"network_route":selectedRoute==2?@"relay":selectedRoute==1?@"direct":@"connecting",@"network_rtt_ms":@(networkRTT.load()),@"network_quality":@(networkQuality.load()),@"audio_engine_started":@(audioStarted),@"minimum_playback_rate":@(playback.minimumRatePPM.load()/1e6),@"maximum_playback_rate":@(playback.maximumRatePPM.load()/1e6),@"received_video_frames":@(streamFrames.load()),@"stream_discontinuities":@(streamGaps.load()),@"recovered_audio_frames":@(recoveredAudio.load()),@"unrecovered_audio_frames":@(unrecoveredAudio.load()),@"received_video_fps":@(sessionFPS.load()),@"displayed_frames":@(displayedFrames),@"skipped_queued_pictures":@(skippedPictures),@"displayed_fps":@(displayedFrames>1?(displayedFrames-1)/std::chrono::duration<double>(lastPicture-firstPicture).count():0),@"drawn_frames":@(view.drawnFrames),@"drawn_fps":@(view.drawnFrames>1?(view.drawnFrames-1)/(view.lastDraw-view.firstDraw):0),@"maximum_draw_gap_ms":@(view.maximumDrawGap*1000),@"maximum_playback_draw_gap_ms":@(view.maximumPlaybackDrawGap*1000),@"playback_draw_stalls":@(view.playbackDrawStalls),@"maximum_ui_tick_gap_ms":@(maximumTickGapMS),@"delayed_ui_ticks":@(delayedTicks),@"display_callbacks":@(displayCallbacks),@"repeated_display_frames":@(repeatedDisplayFrames),@"display_synchronized":@YES,@"display_refresh_hz":@(refreshHz),@"audio_block_ms":@(videoClock.blockDuration()*1000),@"audio_host_lead_ms":@(audioHostLead*1000),@"draw_gaps_over_25ms":@(view.playbackMicrostutters),@"discarded_queued_pictures":@(discardedPictures.load()),@"average_conversion_ms":@(displayedFrames?conversionNS/1e6/displayedFrames:0),@"maximum_conversion_ms":@(maximumConversionNS/1e6),@"rendered_sample_frames":@(playback.rendered.load()),@"underruns":@(playback.underruns.load()),@"backlog_trims":@(playback.trims.load()),@"dropped_sample_frames":@(playback.dropped.load()),@"maximum_buffered_sample_frames":@(playback.maximumBuffered.load())};
   if([config[@"audio_report"] isKindOfClass:NSString.class]){NSData *data=[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:nil];[data writeToFile:config[@"audio_report"] atomically:YES];}
  };
  auto lifecycle=[&](){
   liveInput=controller();
   if(done || closeRequested()){
    [audio stop];[NSApp stop:nil];
    // stop: takes effect after an event. Wake the outer event loop even when
    // this timer fired with no mouse/key event pending.
    [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];
   }
  };
  auto tick=[&](CADisplayLink *link){@autoreleasepool{
   lifecycle();if(done || closeRequested())return;
   ++displayCallbacks;if(link.duration>0)refreshHz=1.0/link.duration;
   auto tickNow=Clock::now();if(lastTick!=Clock::time_point{}){double gap=std::chrono::duration<double,std::milli>(tickNow-lastTick).count();maximumTickGapMS=std::max(maximumTickGapMS,gap);if(gap>50)++delayedTicks;}lastTick=tickNow;
   Bytes pixels;unsigned w=0,h=0,frame=0;std::string role;
   {std::lock_guard<std::mutex> lock(presentation.mutex);audioHostLead=videoClock.hostLead(link.targetTimestamp);videoPosition=std::max(videoPosition,videoPhase.position(link.targetTimestamp,videoClock.position(link.targetTimestamp,videoPosition),videoClock.advancing()));auto position=videoPosition;double playerPosition=CACurrentMediaTime();
    while(!presentation.pictures.empty() && (rollbackPlayer?presentation.pictures.front().deadline<=playerPosition:(!audioStarted || presentation.pictures.front().sample<=position))){
     if(!pixels.empty())++skippedPictures;auto picture=std::move(presentation.pictures.front());presentation.pictures.pop_front();pixels=std::move(picture.pixels);w=picture.width;h=picture.height;frame=picture.frame;role=picture.role;
    }
   }
   if(pixels.empty() && displayedFrames)++repeatedDisplayFrames;
   if(!pixels.empty()){++displayedFrames;lastPicture=Clock::now();if(firstPicture==Clock::time_point{})firstPicture=lastPicture;displayed=frame;auto conversionStart=Clock::now();NSBitmapImageRep *rep=bitmap(pixels,w,h);auto conversionTime=std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now()-conversionStart).count();conversionNS+=conversionTime;maximumConversionNS=std::max(maximumConversionNS,uint64_t(conversionTime));NSImage *image=[[NSImage alloc]initWithSize:NSMakeSize(w,h)];[image addRepresentation:rep];view.picture=image;view.sourceFrame=frame;view.needsDisplay=YES;displayedRole=role;}
   auto uiNow=Clock::now();
   if(uiNow-titleTime>=std::chrono::seconds(1)){double fps=(view.drawnFrames-titleDraws)/std::chrono::duration<double>(uiNow-titleTime).count();titleTime=uiNow;titleDraws=view.drawnFrames;window.title=[NSString stringWithFormat:@"Network Play — %@ — Frame %u — %.1f draw fps · %@ %@%@",ns(displayedRole),displayed,fps,selectedRoute==2?@"Relay":selectedRoute==1?@"Direct":@"Connecting",networkRTT>=0?[NSString stringWithFormat:@"%d ms",networkRTT.load()]:@"",displayedRole=="spectator"?@" · Read-only":@" · Arrows / Z X A S / Q W / Return / Tab"];}
   if(uiNow>=nextReport){diagnostics();nextReport=uiNow+std::chrono::seconds(5);}

   // Draw here as well as on AppKit's normal display pass: tracking modes
   // may defer that pass while the user holds or resizes the window.
   [view displayIfNeeded];
  }};
  // The view's display link follows the actual monitor, including moving
  // between displays. Avoid a free-running timer beating against vsync.
  DisplayDriver *driver=[DisplayDriver new];driver.update=^(CADisplayLink *link){tick(link);};
  CADisplayLink *displayLink=[view displayLinkWithTarget:driver selector:@selector(display:)];
  [displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  // Display links pause for hidden views. Keep input/shutdown responsive then.
  NSTimer *lifecycleTimer=[NSTimer timerWithTimeInterval:0.008 repeats:YES block:^(NSTimer *){lifecycle();}];
  [NSRunLoop.mainRunLoop addTimer:lifecycleTimer forMode:NSRunLoopCommonModes];
  [NSApp run];
  [displayLink invalidate];driver.update=nil;[lifecycleTimer invalidate];closing=true;
  simulation.join();[audio stop];
  diagnostics();
  [window orderOut:nil];return result;
 }catch(const std::exception &e){auto b=json(@{@"error":ns(e.what())});fwrite(b.data(),1,b.size(),stdout);puts("");return 1;}
}}
