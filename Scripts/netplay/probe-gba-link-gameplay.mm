// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#import <Cocoa/Cocoa.h>
#import <OpenEmuBase/OEGameCore.h>
#import <OpenEmuBase/OEGameCoreController.h>
#import <OpenEmuBase/OERingBuffer.h>
#import <CommonCrypto/CommonDigest.h>
#include <mgba/core/core.h>
#include <initializer_list>
#include <vector>
#include <fstream>
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
 require(argc>=4,"usage: probe-gba-link-gameplay CORE_BUNDLE ROM SCRATCH INPUT_TRACE");
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
 struct Input {int frame,player,button,duration;};std::vector<Input> inputs;
 if(argc>4){std::ifstream file(argv[4]);Input e;while(file>>e.frame>>e.player>>e.button>>e.duration)inputs.push_back(e);}
 int cursor=0;
 auto step=[&](int frames,BOOL capture){NSMutableData *output=[NSMutableData new];for(int f=0;f<frames;f++,cursor++){
  for(int i=0;i<2;i++){OEGameCore *c=machines[i];for(int button=0;button<10;button++){BOOL down=NO;for(auto e:inputs)if((e.player==i || e.player==2)&&e.button==button&&cursor>=e.frame&&cursor<e.frame+e.duration)down=YES;if(down)[c didPushGBAButton:button forPlayer:1];else[c didReleaseGBAButton:button forPlayer:1];}[c getVideoBufferWithHint:NULL];}
  require([host executeLinkedFrame],"bounded paired-frame scheduler");NSData *audio=drain(capture);if(capture)[output appendData:audio];
  if(capture)for(OEGameCore *c in machines){const void *pixels=[c getVideoBufferWithHint:NULL];[output appendBytes:pixels length:c.bytesPerRow*c.bufferSize.height];}
 }return output;};
 step(getenv("NX_PROBE_FRAMES")?atoi(getenv("NX_PROBE_FRAMES")):600,NO);
 if(getenv("NX_PROBE_REPLAY")){
 int savedCursor=cursor;NSData *checkpoint=[host serializeLinkedStateWithError:nil];require(checkpoint.length>0,"gameplay checkpoint");
 NSData *out=step(180,YES),*state=[host serializeLinkedStateWithError:nil];
 require([host deserializeLinkedState:checkpoint withError:nil],"gameplay restore");drain(NO);cursor=savedCursor;
 require([out isEqual:step(180,YES)],"gameplay video/audio replay");require([state isEqual:[host serializeLinkedStateWithError:nil]],"gameplay state replay");
 printf("PASS: linked race replay; frame=%d state=%s output=%s\n",cursor,digest(state).UTF8String,digest(out).UTF8String);
 }
 for(int i=0;i<2;i++) { OEGameCore *c=machines[i];const unsigned char *pixels=(const unsigned char *)[c getVideoBufferWithHint:NULL];
 NSBitmapImageRep *image=[[NSBitmapImageRep alloc]initWithBitmapDataPlanes:nil pixelsWide:240 pixelsHigh:160 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:960 bitsPerPixel:32];
 for(int y=0;y<160;y++)memcpy(image.bitmapData+y*960,pixels+y*c.bytesPerRow,960);
 for(int px=0;px<240*160;px++)image.bitmapData[px*4+3]=255;
 [[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}]writeToFile:[@(argv[3]) stringByAppendingPathComponent:[NSString stringWithFormat:@"screen%d.png",i]] atomically:YES];
 }fflush(stdout);_exit(0);
}}
