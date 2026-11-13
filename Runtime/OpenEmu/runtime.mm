// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
// OpenEmu plugin adapter. Each process owns one core and private scratch storage.
#import <Cocoa/Cocoa.h>
#import <OpenEmuBase/OEGameCore.h>
#import <OpenEmuBase/OEGameCoreController.h>
#import <OpenEmuBase/OERingBuffer.h>
#import <CommonCrypto/CommonDigest.h>
#import <OpenGL/gl.h>
#import <objc/message.h>
#include "../Snes9x/emu_runtime.h"
#include <vector>
#include <string>
#include <cstring>
#include <cmath>
@interface OEGameCore (NXRollback)
-(BOOL)connectNetplayPeer:(OEGameCore *)peer;
-(void)disconnectNetplayPeer;
-(BOOL)executeLinkedFrame;
-(NSData *)serializeLinkedStateWithError:(NSError **)error;
-(BOOL)deserializeLinkedState:(NSData *)state withError:(NSError **)error;
-(NSData *)serializeNetplayStateWithError:(NSError **)error;
-(BOOL)deserializeNetplayState:(NSData *)state withError:(NSError **)error;
@end
@interface NXNetplayCoreOwner : OEGameCoreController
@property NSURL *root;
@end
@implementation NXNetplayCoreOwner
-(NSURL *)supportDirectory { return [self.root URLByAppendingPathComponent:@"Support"]; }
-(NSURL *)biosDirectory { return [self.root URLByAppendingPathComponent:@"BIOS"]; }
@end
struct emu_runtime {
 __strong OEGameCore *core, *peer;
 __strong NXNetplayCoreOwner *peerOwner;
 __strong NXNetplayCoreOwner *owner;
 std::vector<uint16_t> video;
 std::vector<int16_t> audio[2];
 uint32_t stateSize=0, phase[2]={0,0};
 unsigned buttons=8;bool nativeSnapshot=false, gba=false;unsigned view=0;
 SEL push=nullptr,release=nullptr;
 int16_t previous[2][2]={{0,0},{0,0}};
 uint32_t frameUS=16667;
};
static emu_runtime *active=nullptr;
static std::string profile;
static NSData *snapshot(emu_runtime *r){return r->gba?[r->core serializeLinkedStateWithError:nil]:r->nativeSnapshot?[r->core serializeNetplayStateWithError:nil]:[r->core serializeStateWithError:nil];}
static std::string sha(NSData *d){unsigned char h[32];CC_SHA256(d.bytes,(CC_LONG)d.length,h);char s[65];for(int i=0;i<32;i++)snprintf(s+i*2,3,"%02x",h[i]);return s;}
uint32_t emu_runtime_abi(){return EMU_RUNTIME_ABI;}
const char *emu_runtime_profile(){return profile.c_str();}
static void drain(emu_runtime *r,OEGameCore *c,unsigned side,bool capture){
 OERingBuffer *ring=(OERingBuffer *)[c audioBufferAtIndex:0];ring.anticipatesUnderflow=NO;
 NSUInteger n=ring.availableBytes;std::vector<int16_t> data((n+1)/2);n=[ring read:data.data() maxLength:n];
 if(!capture)return;
 unsigned channels=(unsigned)c.channelCount,rate=(unsigned)llround(c.audioSampleRate);
 for(size_t i=0;i<n/(2*channels);i++){
  int16_t current[2]={data[i*channels],data[i*channels+(channels==2?1:0)]};
  r->phase[side]+=32040;
  while(r->phase[side]>=rate){r->phase[side]-=rate;double t=1.0-double(r->phase[side])/32040;
   for(int ch=0;ch<2;ch++)r->audio[side].push_back((int16_t)llround(r->previous[side][ch]+(current[ch]-r->previous[side][ch])*t));
  }
  memcpy(r->previous[side],current,sizeof(current));
 }
}
void emu_destroy(emu_runtime *r){if(!r || r!=active)return;NSURL *root=r->owner.root;active=nullptr;if(r->gba && [r->core respondsToSelector:@selector(disconnectNetplayPeer)])[r->core disconnectNetplayPeer];delete r;[[NSFileManager defaultManager]removeItemAtURL:root error:nil];}
int32_t emu_create(uint32_t abi,const uint8_t *rom,uint32_t length,emu_runtime **out){@autoreleasepool{
 if(!out)return EMU_ARGUMENT;*out=nullptr;if(abi!=EMU_RUNTIME_ABI)return EMU_ABI;if(active)return EMU_BUSY;
 if(!rom || !length || length>64*1024*1024)return EMU_ROM;
 NSDictionary *env=NSProcessInfo.processInfo.environment;
 NSString *path=env[@"NX_NETPLAY_CORE"],*system=env[@"NX_NETPLAY_SYSTEM"];
 if(!path.length || !system.length)return EMU_ARGUMENT;
 NSBundle *bundle=[NSBundle bundleWithPath:path];NSError *error=nil;
 if(![bundle.infoDictionary[@"OESystemIdentifiers"] containsObject:system] || ![bundle loadAndReturnError:&error])return EMU_ROM;
 bool genesis=[system isEqual:@"openemu.system.sg"],gba=[system isEqual:@"openemu.system.gba"];
 if(!genesis && !gba && ![system isEqual:@"openemu.system.nes"])return EMU_ABI;
 emu_runtime *r=new emu_runtime;active=r;
 r->gba=gba;r->view=gba && [env[@"NX_NETPLAY_VIEW"] isEqual:@"1"]?1:0;
 r->buttons=gba?10:genesis?12:8;r->nativeSnapshot=genesis || gba;
 r->push=NSSelectorFromString(gba?@"didPushGBAButton:forPlayer:":genesis?@"didPushGenesisButton:forPlayer:":@"didPushNESButton:forPlayer:");
 r->release=NSSelectorFromString(gba?@"didReleaseGBAButton:forPlayer:":genesis?@"didReleaseGenesisButton:forPlayer:":@"didReleaseNESButton:forPlayer:");
 r->owner=[[NXNetplayCoreOwner alloc]initWithBundle:bundle];
 r->owner.root=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"NX-core-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
 for(NSURL *url in @[r->owner.supportDirectory,r->owner.biosDirectory])[[NSFileManager defaultManager]createDirectoryAtURL:url withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
 r->core=[r->owner newGameCore];r->core.owner=r->owner;r->core.systemIdentifier=system;
 NSURL *file=[r->owner.root URLByAppendingPathComponent:gba?@"game.gba":genesis?@"game.gen":@"game.nes"];
 if(![[NSData dataWithBytes:rom length:length]writeToURL:file options:NSDataWritingAtomic error:&error] || ![r->core loadFileAtPath:file.path error:&error]){emu_destroy(r);return EMU_ROM;}
 dispatch_semaphore_t ready=dispatch_semaphore_create(0);[r->core setupEmulationWithCompletionHandler:^{dispatch_semaphore_signal(ready);}];
 NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:20];
 while(dispatch_semaphore_wait(ready,DISPATCH_TIME_NOW)){if(deadline.timeIntervalSinceNow<0){emu_destroy(r);return EMU_INTERNAL;}[[NSRunLoop currentRunLoop]runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];}
 OEGameCore *c=r->core;
 if(c.gameCoreRendering!=OEGameCoreRenderingBitmap || c.audioBufferCount!=1 || c.audioBitDepth!=16 || c.channelCount<1 || c.channelCount>2 || c.audioSampleRate<8000 || c.audioSampleRate>192000 || c.frameInterval<20 || c.frameInterval>120 || ![c respondsToSelector:@selector(serializeStateWithError:)] || ![c respondsToSelector:@selector(deserializeState:withError:)] || ![c respondsToSelector:r->push] || ![c respondsToSelector:r->release] || ((genesis || gba) && (![c respondsToSelector:@selector(serializeNetplayStateWithError:)] || ![c respondsToSelector:@selector(deserializeNetplayState:withError:)]))){emu_destroy(r);return EMU_ABI;}
 if(gba){
  if(![c respondsToSelector:@selector(connectNetplayPeer:)] || ![c respondsToSelector:@selector(executeLinkedFrame)] || ![c respondsToSelector:@selector(serializeLinkedStateWithError:)] || ![c respondsToSelector:@selector(deserializeLinkedState:withError:)]){emu_destroy(r);return EMU_ABI;}
  r->peerOwner=[[NXNetplayCoreOwner alloc]initWithBundle:bundle];r->peerOwner.root=[r->owner.root URLByAppendingPathComponent:@"Player2"];
  for(NSURL *url in @[r->peerOwner.supportDirectory,r->peerOwner.biosDirectory])[[NSFileManager defaultManager]createDirectoryAtURL:url withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
  r->peer=[r->peerOwner newGameCore];r->peer.owner=r->peerOwner;r->peer.systemIdentifier=system;
  if(![r->peer loadFileAtPath:file.path error:&error]){emu_destroy(r);return EMU_ROM;}
  dispatch_semaphore_t peerReady=dispatch_semaphore_create(0);[r->peer setupEmulationWithCompletionHandler:^{dispatch_semaphore_signal(peerReady);}];
  NSDate *peerDeadline=[NSDate dateWithTimeIntervalSinceNow:20];
  while(dispatch_semaphore_wait(peerReady,DISPATCH_TIME_NOW)){if(peerDeadline.timeIntervalSinceNow<0){emu_destroy(r);return EMU_INTERNAL;}[[NSRunLoop currentRunLoop]runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];}
  if(![c connectNetplayPeer:r->peer]){emu_destroy(r);return EMU_INTERNAL;}
 }
 NSData *state=snapshot(r);if(!state.length || state.length>2*1024*1024){emu_destroy(r);return EMU_STATE;}
 // GBA save memory can be discovered after boot; reserve bounded snapshot space.
 r->stateSize=gba?2*1024*1024:uint32_t(state.length)+64;r->frameUS=uint32_t(llround(1000000/c.frameInterval));
 NSData *binary=[NSData dataWithContentsOfURL:bundle.executableURL];if(!binary.length){emu_destroy(r);return EMU_INTERNAL;}
 profile=std::string(gba?"oe1.gbalink.":genesis?"oe1.sg.":"oe1.nes.")+sha(binary);*out=r;return EMU_OK;
}}
uint32_t emu_frame_duration_us(emu_runtime *r){return r?r->frameUS:0;}
int32_t emu_step(emu_runtime *r,uint16_t p1,uint16_t p2,emu_frame *out){@autoreleasepool{
 if(r!=active || !r || !out || ((p1|p2)&~((1u<<r->buttons)-1)))return EMU_ARGUMENT;
 OEGameCore *c=r->core;
 for(unsigned player=1;player<=2;player++)for(unsigned b=0;b<r->buttons;b++){
  SEL s=((player==1?p1:p2)&(1<<b))?r->push:r->release;
  OEGameCore *target=r->gba && player==2?r->peer:c;
  ((void(*)(id,SEL,NSUInteger,NSUInteger))objc_msgSend)(target,s,b,r->gba?1:player);
 }
 OEGameCore *screen=r->view?r->peer:c;
 const uint8_t *pixels=(const uint8_t *)[screen getVideoBufferWithHint:nullptr];
 if(r->gba){[c getVideoBufferWithHint:nullptr];[r->peer getVideoBufferWithHint:nullptr];if(![c executeLinkedFrame])return EMU_INTERNAL;}else [c executeFrame];
 c=screen;
 OEIntRect rect=c.screenRect;OEIntSize size=c.bufferSize;
 if(!pixels || rect.origin.x<0 || rect.origin.y<0 || rect.size.width<=0 || rect.size.height<=0 || rect.origin.x+rect.size.width>size.width || rect.origin.y+rect.size.height>size.height || size.width>2048 || size.height>2048 || c.bytesPerRow<size.width*4 || (c.pixelFormat!=GL_BGRA && c.pixelFormat!=GL_RGBA) || c.pixelType!=GL_UNSIGNED_INT_8_8_8_8_REV)return EMU_INTERNAL;
 r->video.resize(rect.size.width*rect.size.height);
 for(int y=0;y<rect.size.height;y++)for(int x=0;x<rect.size.width;x++){
  const uint8_t *p=pixels+(y+rect.origin.y)*c.bytesPerRow+(x+rect.origin.x)*4;
  r->video[y*rect.size.width+x]=uint16_t(((p[c.pixelFormat==GL_RGBA?0:2]>>3)<<11)|((p[1]>>2)<<5)|(p[c.pixelFormat==GL_RGBA?2:0]>>3));
 }
 for(unsigned side=0;side<(r->gba?2:1);side++){r->audio[side].clear();drain(r,side?r->peer:r->core,side,true);}
 *out={r->video.data(),uint32_t(rect.size.width),uint32_t(rect.size.height),uint32_t(rect.size.width),r->audio[r->view].data(),uint32_t(r->audio[r->view].size()/2)};return EMU_OK;
}}
int32_t emu_state_size(emu_runtime *r,uint32_t *size){if(!r || r!=active || !size)return EMU_ARGUMENT;*size=r->stateSize;return EMU_OK;}
int32_t emu_state_copy(emu_runtime *r,uint8_t *out,uint32_t capacity){@autoreleasepool{
 if(!r || r!=active || !out)return EMU_ARGUMENT;if(capacity<r->stateSize)return EMU_BUFFER;
 NSData *d=snapshot(r);if(!d.length || d.length+64>r->stateSize)return EMU_STATE;
 memset(out,0,r->stateSize);memcpy(out,"NXOEABI2",8);uint32_t length=(uint32_t)d.length;
 memcpy(out+8,&length,4);memcpy(out+12,r->phase,8);memcpy(out+20,r->previous,8);memcpy(out+64,d.bytes,d.length);return EMU_OK;
}}
int32_t emu_state_restore(emu_runtime *r,const uint8_t *data,uint32_t size){@autoreleasepool{
 if(!r || r!=active || !data || size!=r->stateSize || memcmp(data,"NXOEABI2",8))return EMU_STATE;
 uint32_t length,phase[2];memcpy(&length,data+8,4);memcpy(phase,data+12,8);
 if(length>size-64 || phase[0]>=(uint32_t)llround(r->core.audioSampleRate) || phase[1]>=(uint32_t)llround(r->core.audioSampleRate))return EMU_STATE;
 NSData *state=[NSData dataWithBytes:data+64 length:length];
 BOOL restored=r->gba?[r->core deserializeLinkedState:state withError:nil]:r->nativeSnapshot?[r->core deserializeNetplayState:state withError:nil]:[r->core deserializeState:state withError:nil];
 if(!restored)return EMU_STATE;
 memcpy(r->phase,phase,8);memcpy(r->previous,data+20,8);for(unsigned side=0;side<(r->gba?2:1);side++){drain(r,side?r->peer:r->core,side,false);r->audio[side].clear();}return EMU_OK;
}}
