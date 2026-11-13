// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#import <Cocoa/Cocoa.h>
#import <OpenEmuBase/OEGameCore.h>
#import <OpenEmuBase/OEGameCoreController.h>
#import <OpenEmuBase/OEAudioBuffer.h>
#import <OpenEmuBase/OERingBuffer.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
@interface OEGameCore (NXRollback)
-(NSData *)serializeNetplayStateWithError:(NSError **)error;
-(BOOL)deserializeNetplayState:(NSData *)state withError:(NSError **)error;
@end
@interface IsolatedOwner : OEGameCoreController
@property NSURL *root;
@end
@implementation IsolatedOwner
-(NSURL *)supportDirectory { return [self.root URLByAppendingPathComponent:@"Support"]; }
-(NSURL *)biosDirectory { return [self.root URLByAppendingPathComponent:@"BIOS"]; }
@end
static NSString *digest(NSData *d) { unsigned char b[32];CC_SHA256(d.bytes,(CC_LONG)d.length,b);NSMutableString *s=[NSMutableString new];for(int i=0;i<32;i++)[s appendFormat:@"%02x",b[i]];return s; }
int main(int argc,char **argv){ @autoreleasepool {
 if(argc!=5){fprintf(stderr,"Usage: probe CORE_BUNDLE SYSTEM_ID EXTRACTED_ROM SCRATCH_DIRECTORY\n");return 2;}
 NSBundle *b=[NSBundle bundleWithPath:@(argv[1])];NSError *e=nil;
 if(![b loadAndReturnError:&e]){fprintf(stderr,"%s\n",e.description.UTF8String);return 3;}
 IsolatedOwner *owner=[[IsolatedOwner alloc]initWithBundle:b];owner.root=[NSURL fileURLWithPath:@(argv[4])];
 for(NSURL *u in @[owner.supportDirectory,owner.biosDirectory])[[NSFileManager defaultManager]createDirectoryAtURL:u withIntermediateDirectories:YES attributes:nil error:nil];
 OEGameCore *c=[owner newGameCore];c.owner=owner;c.systemIdentifier=@(argv[2]);
 if(![c loadFileAtPath:@(argv[3]) error:&e]){fprintf(stderr,"load: %s\n",e.description.UTF8String);return 4;}
 dispatch_semaphore_t ready=dispatch_semaphore_create(0);[c setupEmulationWithCompletionHandler:^{dispatch_semaphore_signal(ready);}];
 NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:20];
 while(dispatch_semaphore_wait(ready,DISPATCH_TIME_NOW)){if(deadline.timeIntervalSinceNow<0)return 5;[[NSRunLoop currentRunLoop]runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];}
 if(c.gameCoreRendering!=OEGameCoreRenderingBitmap){puts("{\"result\":\"needs_gpu_adapter\"}");return 0;}
 if(![c respondsToSelector:@selector(serializeStateWithError:)] || ![c respondsToSelector:@selector(deserializeState:withError:)]){puts("{\"result\":\"needs_state_adapter\"}");return 0;}
 auto drain=[&](){NSMutableData *d=[NSMutableData new];for(NSUInteger i=0;i<c.audioBufferCount;i++){id<OEAudioBuffer> ring=[c audioBufferAtIndex:i];[(OERingBuffer *)ring setAnticipatesUnderflow:NO];char buf[65536];NSUInteger n;while((n=[ring read:buf maxLength:MIN(sizeof(buf),[(OERingBuffer *)ring availableBytes])])){[d appendBytes:buf length:n];}}return d;};
 bool gba=[c.systemIdentifier isEqual:@"openemu.system.gba"];
 SEL push=NSSelectorFromString(gba?@"didPushGBAButton:forPlayer:":@"didPushGenesisButton:forPlayer:");
 SEL release=NSSelectorFromString(gba?@"didReleaseGBAButton:forPlayer:":@"didReleaseGenesisButton:forPlayer:");
 auto input=[&](unsigned frame){for(unsigned player=1;player<=(gba?1:2);player++)for(unsigned button=0;button<(gba?10:12);button++){
 unsigned mask=((frame%120==60)?(1u<<(gba?8:10)):0)|((frame%60<20)?(1u<<4):0)|((frame%90<30)?8:0);
 ((void(*)(id,SEL,NSUInteger,NSUInteger))objc_msgSend)(c,(mask&(1u<<button))?push:release,button,player);
 }};
 auto step=[&](int frames){NSMutableData *a=[NSMutableData new];for(int i=0;i<frames;i++){input(i);[c getVideoBufferWithHint:NULL];[c executeFrame];[a appendData:drain()];}return a;};
 auto snapshot=[&](){return [c respondsToSelector:@selector(serializeNetplayStateWithError:)]?[c serializeNetplayStateWithError:&e]:[c serializeStateWithError:&e];};
 auto restore=[&](NSData *state){return [c respondsToSelector:@selector(deserializeNetplayState:withError:)]?[c deserializeNetplayState:state withError:&e]:[c deserializeState:state withError:&e];};
 step(1200);NSData *checkpoint=snapshot();if(!checkpoint.length)return 6;
 auto start=NSDate.date;NSData *audio=step(180);double elapsed=-start.timeIntervalSinceNow;
 NSData *first=snapshot();NSString *expected=digest(first);
 if(!restore(checkpoint))return 7;drain();NSData *replayAudio=step(180);NSData *second=snapshot();
 [first writeToFile:[@(argv[4]) stringByAppendingPathComponent:@"first.state"] atomically:YES];[second writeToFile:[@(argv[4]) stringByAppendingPathComponent:@"replay.state"] atomically:YES];
 NSDictionary *report=@{@"system":c.systemIdentifier,@"core":b.bundleIdentifier,@"version":b.infoDictionary[@"CFBundleVersion"]?:@"",@"state_bytes":@(checkpoint.length),@"state_hash":expected,@"replay_state_equal":@([first isEqual:second]),@"audio_bytes":@(audio.length),@"replay_audio_equal":@([audio isEqual:replayAudio]),@"audio_rate":@(c.audioSampleRate),@"channels":@(c.channelCount),@"audio_bits":@(c.audioBitDepth),@"fps":@(c.frameInterval),@"execution_fps":@(180/elapsed)};
 puts([[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil] encoding:NSUTF8StringEncoding].UTF8String);
 // Do not call stopEmulation: several plugins write battery saves on stop.
 fflush(stdout); _exit(([first isEqual:second] && [audio isEqual:replayAudio])?0:8);
}}
