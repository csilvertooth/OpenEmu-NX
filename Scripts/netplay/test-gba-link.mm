// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#import <Cocoa/Cocoa.h>
#import <OpenEmuBase/OEGameCore.h>
#import <OpenEmuBase/OEGameCoreController.h>
#import <OpenEmuBase/OERingBuffer.h>
#import <CommonCrypto/CommonDigest.h>
#include <mgba/core/core.h>
#include <initializer_list>
@interface OEGameCore (NXLink)
-(struct mCore *)mCore;
-(BOOL)connectNetplayPeer:(OEGameCore *)peer;
-(void)disconnectNetplayPeer;
-(BOOL)executeLinkedFrame;
-(NSData *)serializeLinkedStateWithError:(NSError **)error;
-(BOOL)deserializeLinkedState:(NSData *)state withError:(NSError **)error;
-(void)didPushGBAButton:(NSUInteger)b forPlayer:(NSUInteger)p;
-(void)didReleaseGBAButton:(NSUInteger)b forPlayer:(NSUInteger)p;
@end
@interface NXTestOwner : OEGameCoreController
@property NSURL *root;
@end
@implementation NXTestOwner
-(NSURL *)supportDirectory{return [self.root URLByAppendingPathComponent:@"Support"];}
-(NSURL *)biosDirectory{return [self.root URLByAppendingPathComponent:@"BIOS"];}
@end
static NSString *digest(NSData *d){unsigned char bytes[32];CC_SHA256(d.bytes,(CC_LONG)d.length,bytes);NSMutableString *s=[NSMutableString new];for(int i=0;i<32;i++)[s appendFormat:@"%02x",bytes[i]];return s;}
static void require(bool ok,const char *message){if(!ok){fprintf(stderr,"FAIL %s\n",message);exit(1);}}
int main(int argc,char **argv){@autoreleasepool{
 require(argc==4,"usage: test-link CORE_BUNDLE ROM SCRATCH");
 NSBundle *bundle=[NSBundle bundleWithPath:@(argv[1])];require([bundle load],"load bundle");
 NSMutableArray *owners=[NSMutableArray new],*machines=[NSMutableArray new];
 for(int i=0;i<2;i++){
  NXTestOwner *owner=[[NXTestOwner alloc]initWithBundle:bundle];owner.root=[NSURL fileURLWithPath:[@(argv[3]) stringByAppendingPathComponent:[NSString stringWithFormat:@"player%d",i]]];
  for(NSURL *u in @[owner.supportDirectory,owner.biosDirectory])[[NSFileManager defaultManager]createDirectoryAtURL:u withIntermediateDirectories:YES attributes:nil error:nil];
  OEGameCore *c=[owner newGameCore];c.owner=owner;c.systemIdentifier=@"openemu.system.gba";
  require([c loadFileAtPath:@(argv[2]) error:nil],"load ROM");
  __block BOOL ready=NO;[c setupEmulationWithCompletionHandler:^{ready=YES;}];
  NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:20];while(!ready && deadline.timeIntervalSinceNow>0)[[NSRunLoop currentRunLoop]runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
  require(ready,"setup deadline");[owners addObject:owner];[machines addObject:c];
 }
 OEGameCore *host=machines[0],*guest=machines[1];require([host connectNetplayPeer:guest],"connect two handhelds");
 auto drain=[&](BOOL capture){NSMutableData *data=[NSMutableData new];for(OEGameCore *c in machines){OERingBuffer *b=(id)[c audioBufferAtIndex:0];b.anticipatesUnderflow=NO;char bytes[8192];NSUInteger n;while((n=[b read:bytes maxLength:MIN(sizeof(bytes),b.availableBytes)]))if(capture)[data appendBytes:bytes length:n];}return data;};
 auto step=[&](int frames){NSMutableData *output=[NSMutableData new];for(int f=0;f<frames;f++){
  for(int i=0;i<2;i++){OEGameCore *c=machines[i];for(int button=0;button<10;button++){BOOL down=(button==8 && f%120==60)||(button==4 && f%60==30+i);if(down)[c didPushGBAButton:button forPlayer:1];else[c didReleaseGBAButton:button forPlayer:1];}[c getVideoBufferWithHint:NULL];}
  require([host executeLinkedFrame],"bounded paired-frame scheduler");[output appendData:drain(YES)];
  for(OEGameCore *c in machines){const void *pixels=[c getVideoBufferWithHint:NULL];[output appendBytes:pixels length:c.bytesPerRow*c.bufferSize.height];}
 }return output;};
 step(120);
 struct mCore *a=[host mCore],*b=[guest mCore];
 for(int baud=0;baud<4;baud++){
  for(struct mCore *c:{a,b}){c->busWrite16(c,0x04000134,0);c->busWrite16(c,0x04000128,0x2000|baud);}
  step(1);a->busWrite16(a,0x0400012a,0x1234+baud);b->busWrite16(b,0x0400012a,0xabcd-baud);a->busWrite16(a,0x04000128,0x2080|baud);
  NSData *pending=[host serializeLinkedStateWithError:nil];require(pending.length>0,"in-flight snapshot");
  NSData *out=step(1),*state=[host serializeLinkedStateWithError:nil];
  for(struct mCore *c:{a,b}){require(c->busRead16(c,0x04000120)==0x1234+baud,"master serial word");require(c->busRead16(c,0x04000122)==0xabcd-baud,"slave serial word");}
  require([host deserializeLinkedState:pending withError:nil],"restore in-flight transfer");drain(NO);
  require([out isEqual:step(1)],"in-flight video/audio replay");require([state isEqual:[host serializeLinkedStateWithError:nil]],"in-flight cable/core state replay");
 }
 NSData *checkpoint=[host serializeLinkedStateWithError:nil];NSDate *start=NSDate.date;
 NSData *out=step(180);double elapsed=-start.timeIntervalSinceNow;NSData *state=[host serializeLinkedStateWithError:nil];
 require([host deserializeLinkedState:checkpoint withError:nil],"restore pair");drain(NO);
 require([out isEqual:step(180)],"pair video/audio replay");require([state isEqual:[host serializeLinkedStateWithError:nil]],"pair final state");
 NSDictionary *report=@{@"result":@"PASS",@"handhelds":@2,@"serial_baud_modes":@4,@"rollback_frames":@180,@"state_sha256":digest(state),@"video_audio_sha256":digest(out),@"pair_fps":@(180/elapsed)};
 puts([[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil] encoding:NSUTF8StringEncoding].UTF8String);
 [host disconnectNetplayPeer];fflush(stdout);_exit(0);
}}
