/*
 Copyright (c) 2016, Jeffrey Pfau

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS ''AS IS''
 AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 POSSIBILITY OF SUCH DAMAGE.
 */

#import "mGBAGameCore.h"


#include <mgba-util/common.h>

#include <mgba/core/blip_buf.h>
#include <mgba/core/core.h>
#include <mgba/core/cheats.h>
#include <mgba/core/serialize.h>
#include <mgba/gba/core.h>
#include <mgba/internal/gba/cheats.h>
#include <mgba/internal/gba/input.h>
#include <mgba/internal/gba/gba.h>
#include <mgba-util/circle-buffer.h>
#include <mgba-util/memory.h>
#include <mgba-util/vfs.h>

#import <OpenEmuBase/OEGameCoreController.h>
#import <OpenEmuBase/OERingBuffer.h>
#import <OpenEmuBase/OEMemoryRegionDescriptor.h>
#import "OEGBASystemResponderClient.h"
#import <OpenGL/gl.h>

#define RC_CLIENT_SUPPORTS_HASH 1
#include <rc_client.h>
#include <rc_consoles.h>
#import "OERetroAchievementsTransport.h"
#import "OERetroAchievementsBridge.h"

#include "NXGBALink.h"

#define SAMPLES 1024

// Session payload keys and notification name are defined in OERetroAchievementsTransport.h.

#ifdef DEBUG
    #error "Cores should not be compiled in DEBUG! Follow the guide https://github.com/OpenEmu/OpenEmu/wiki/Compiling-From-Source-Guide"
#endif

const char* const binaryName = "mGBA";
const char* const projectName = "mGBA";
const char* projectVersion;

@interface mGBAGameCore () <OEGBASystemResponderClient>
{
	struct mCore* core;
	void* outputBuffer;
	NSMutableDictionary *cheatSets;
	OERetroAchievementsBridge *_raBridge;
    NSString *_romPath;
    struct NXGBALink *_netplayLink;
    mGBAGameCore *_netplayPeer;
    __weak mGBAGameCore *_netplayHost;
}
- (struct mCore *)mCore;
@end

// rcheevos GBA address space → hardware bus address:
//   0x000000–0x007FFF  →  IWRAM  0x03000000
//   0x008000–0x047FFF  →  EWRAM  0x02000000
//   0x048000–0x057FFF  →  SRAM   0x0E000000
static uint32_t gba_rc_to_hw(uint32_t addr) {
    if (addr < 0x008000) return 0x03000000 + addr;
    if (addr < 0x048000) return 0x02000000 + (addr - 0x008000);
    if (addr < 0x058000) return 0x0E000000 + (addr - 0x048000);
    return addr;
}

static uint32_t mGBA_rc_read_memory(uint32_t address, uint8_t *buffer,
                                     uint32_t num_bytes, rc_client_t *client)
{
    OERetroAchievementsBridge *bridge = (__bridge OERetroAchievementsBridge *)rc_client_get_userdata(client);
    mGBAGameCore *c = (mGBAGameCore *)bridge.core;
    if (!c) { return 0; }
    struct mCore *mcore = [c mCore];
    if (!mcore) { return 0; }
    for (uint32_t i = 0; i < num_bytes; i++) {
        uint32_t a = address + i;
        if (a >= 0x058000) { return i; }  // past SRAM region — short-read.
        buffer[i] = mcore->busRead8(mcore, gba_rc_to_hw(a));
    }
    return num_bytes;
}


static void _log(struct mLogger* log,
                 int category,
                 enum mLogLevel level,
                 const char* format,
                 va_list args)
{}

static struct mLogger logger = { .log = _log };

@implementation mGBAGameCore

- (struct mCore *)mCore { return core; }

- (id)init
{
	if ((self = [super init]))
	{
		core = GBACoreCreate();
		mCoreInitConfig(core, nil);

		struct mCoreOptions opts = {
			.useBios = true,
		};
        
        // Set up a logger. The default logger prints everything to STDOUT, which is not usually desirable.
        mLogSetDefaultLogger(&logger);

		mCoreConfigLoadDefaults(&core->config, &opts);
		core->init(core);
		outputBuffer = nil;

		unsigned width, height;
		core->desiredVideoDimensions(core, &width, &height);
		outputBuffer = malloc(width * height * BYTES_PER_PIXEL);
		core->setVideoBuffer(core, outputBuffer, width);
		core->setAudioBufferSize(core, SAMPLES);

		cheatSets = [[NSMutableDictionary alloc] init];
	}

	return self;
}


- (void)retroAchievementsIdle
{
    [_raBridge idle];
}

- (BOOL)canPauseRetroAchievementsHardcoreWithFramesRemaining:(uint32_t *)framesRemaining
{
    return _raBridge ? [_raBridge canPauseWithFramesRemaining:framesRemaining] : YES;
}

- (NSData *)retroAchievementsSerializedProgress
{
    return [_raBridge serializeProgress];
}

- (void)retroAchievementsDeserializeProgress:(NSData *)data
{
    [_raBridge deserializeProgress:data];
}

- (void)dealloc
{
    if(_netplayLink)NXLinkDestroy(_netplayLink);
    mCoreConfigDeinit(&core->config);
	core->deinit(core);
	free(outputBuffer);
}

#pragma mark - Execution

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    projectVersion = [self.owner.bundle.infoDictionary[@"CFBundleVersion"] UTF8String];

	NSString *batterySavesDirectory = [self batterySavesDirectoryPath];
	[[NSFileManager defaultManager] createDirectoryAtURL:[NSURL fileURLWithPath:batterySavesDirectory]
	                                withIntermediateDirectories:YES
	                                attributes:nil
	                                error:nil];
	if (core->dirs.save) {
		core->dirs.save->close(core->dirs.save);
	}
	core->dirs.save = VDirOpen([batterySavesDirectory fileSystemRepresentation]);

	if (!mCoreLoadFile(core, [path fileSystemRepresentation])) {
		if (error) {
			*error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError userInfo:nil];
		}
		return NO;
	}
	mCoreAutoloadSave(core);

	core->reset(core);

    _romPath = path;
    _raBridge = [[OERetroAchievementsBridge alloc] initWithGameCore:self
                                                        memoryReader:mGBA_rc_read_memory
                                                           consoleID:RC_CONSOLE_GAMEBOY_ADVANCE];
    [_raBridge startWithROMPath:path];
    [_raBridge markROMReady];

	return YES;
}

- (void)executeFrame
{
	core->runFrame(core);

	[_raBridge doFrame];

    [self drainNetplayAudio];
}

- (void)drainNetplayAudio
{
    int16_t samples[SAMPLES * 2];
    size_t available;
    while((available=MIN(SAMPLES,blip_samples_avail(core->getAudioChannel(core,0))))) {
        blip_read_samples(core->getAudioChannel(core,0),samples,available,true);
        blip_read_samples(core->getAudioChannel(core,1),samples+1,available,true);
        [[self audioBufferAtIndex:0] write:samples maxLength:available*4];
    }
}

// Private two-machine API. The caller owns both machines on one emulation thread.
- (BOOL)connectNetplayPeer:(mGBAGameCore *)peer
{
    if(!peer || peer==self || _netplayLink || _netplayHost || peer->_netplayLink || peer->_netplayHost)return NO;
    _netplayLink=NXLinkCreate(core,peer->core);if(!_netplayLink)return NO;
    _netplayPeer=peer;peer->_netplayHost=self;return YES;
}
- (void)disconnectNetplayPeer
{
    if(!_netplayLink)return;
    NXLinkDestroy(_netplayLink);_netplayLink=NULL;_netplayPeer->_netplayHost=nil;_netplayPeer=nil;
}
- (BOOL)executeLinkedFrame
{
    if(!_netplayLink || !NXLinkFrame(_netplayLink))return NO;
    [self drainNetplayAudio];[_netplayPeer drainNetplayAudio];return YES;
}
- (NSData *)serializeLinkedStateWithError:(NSError **)error
{
    if(!_netplayLink)return nil;
    NSData *a=[self serializeNetplayStateWithError:error],*b=[_netplayPeer serializeNetplayStateWithError:error];
    if(!a || !b)return nil;
    uint32_t lengths[2]={(uint32_t)a.length,(uint32_t)b.length};
    struct NXGBALinkState cable=NXLinkSave(_netplayLink);
    NSMutableData *d=[NSMutableData dataWithBytes:"NXGBPAIR" length:8];
    [d appendBytes:lengths length:8];[d appendBytes:&cable length:sizeof(cable)];[d appendData:a];[d appendData:b];return d;
}
- (BOOL)deserializeLinkedState:(NSData *)data withError:(NSError **)error
{
    size_t header=16+sizeof(struct NXGBALinkState);if(!_netplayLink || data.length<header)return NO;
    const unsigned char *p=data.bytes;uint32_t lengths[2];memcpy(lengths,p+8,8);
    if(memcmp(p,"NXGBPAIR",8) || lengths[0]>2*1024*1024 || lengths[1]>2*1024*1024 || data.length!=header+lengths[0]+lengths[1])return NO;
    struct NXGBALinkState cable;memcpy(&cable,p+16,sizeof(cable));
    if(cable.version!=2)return NO;
    NXLinkPrepareLoad(_netplayLink);
    if(![self deserializeNetplayState:[NSData dataWithBytes:p+header length:lengths[0]] withError:error] ||
       ![_netplayPeer deserializeNetplayState:[NSData dataWithBytes:p+header+lengths[0] length:lengths[1]] withError:error])return NO;
    return NXLinkLoad(_netplayLink,&cable);
}

- (void)stopEmulation
{
    [_raBridge shutdown];
    _raBridge = nil;
    [super stopEmulation];
}

- (void)resetEmulation
{
	[_raBridge reset];
	core->reset(core);
}

- (void)setupEmulation
{
	blip_set_rates(core->getAudioChannel(core, 0), core->frequency(core), 32768);
	blip_set_rates(core->getAudioChannel(core, 1), core->frequency(core), 32768);
}

#pragma mark - Video

- (OEIntSize)aspectSize
{
	return OEIntSizeMake(3, 2);
}

- (OEIntRect)screenRect
{
	unsigned width, height;
	core->desiredVideoDimensions(core, &width, &height);
    return OEIntRectMake(0, 0, width, height);
}

- (OEIntSize)bufferSize
{
	unsigned width, height;
	core->desiredVideoDimensions(core, &width, &height);
    return OEIntSizeMake(width, height);
}

- (const void *)getVideoBufferWithHint:(void *)hint
{
	OEIntSize bufferSize = [self bufferSize];

	if (!hint)
	{
		hint = outputBuffer;
	}

	outputBuffer = hint;
	core->setVideoBuffer(core, hint, bufferSize.width);

	return hint;
}

- (GLenum)pixelFormat
{
    return GL_RGBA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_INT_8_8_8_8_REV;
}

- (NSTimeInterval)frameInterval
{
	return core->frequency(core) / (double) core->frameCycles(core);
}

#pragma mark - Audio

- (NSUInteger)channelCount
{
    return 2;
}

- (double)audioSampleRate
{
    return 32768;
}

#pragma mark - Save State


// Capture channel caches omitted by disk saves, without pointers or struct padding.
// This private format is local to a matched core binary, at frame boundaries.
static size_t NXPSGSnapshot(struct GBAudio *a, unsigned char *p, BOOL load)
{
    size_t n=0;
#define NX_FIELD(f) do { if(p) { if(load)memcpy(&a->f,p+n,sizeof(a->f));else memcpy(p+n,&a->f,sizeof(a->f)); } n+=sizeof(a->f); } while(0)
    NX_FIELD(ch1.sweep.shift);
    NX_FIELD(ch1.sweep.time);
    NX_FIELD(ch1.sweep.step);
    NX_FIELD(ch1.sweep.direction);
    NX_FIELD(ch1.sweep.enable);
    NX_FIELD(ch1.sweep.occurred);
    NX_FIELD(ch1.sweep.realFrequency);
    NX_FIELD(ch1.envelope.length);
    NX_FIELD(ch1.envelope.duty);
    NX_FIELD(ch1.envelope.stepTime);
    NX_FIELD(ch1.envelope.initialVolume);
    NX_FIELD(ch1.envelope.currentVolume);
    NX_FIELD(ch1.envelope.direction);
    NX_FIELD(ch1.envelope.dead);
    NX_FIELD(ch1.envelope.nextStep);
    NX_FIELD(ch1.control.frequency);
    NX_FIELD(ch1.control.length);
    NX_FIELD(ch1.control.stop);
    NX_FIELD(ch1.lastUpdate);
    NX_FIELD(ch1.index);
    NX_FIELD(ch1.sample);
    NX_FIELD(ch2.sweep.shift);
    NX_FIELD(ch2.sweep.time);
    NX_FIELD(ch2.sweep.step);
    NX_FIELD(ch2.sweep.direction);
    NX_FIELD(ch2.sweep.enable);
    NX_FIELD(ch2.sweep.occurred);
    NX_FIELD(ch2.sweep.realFrequency);
    NX_FIELD(ch2.envelope.length);
    NX_FIELD(ch2.envelope.duty);
    NX_FIELD(ch2.envelope.stepTime);
    NX_FIELD(ch2.envelope.initialVolume);
    NX_FIELD(ch2.envelope.currentVolume);
    NX_FIELD(ch2.envelope.direction);
    NX_FIELD(ch2.envelope.dead);
    NX_FIELD(ch2.envelope.nextStep);
    NX_FIELD(ch2.control.frequency);
    NX_FIELD(ch2.control.length);
    NX_FIELD(ch2.control.stop);
    NX_FIELD(ch2.lastUpdate);
    NX_FIELD(ch2.index);
    NX_FIELD(ch2.sample);
    NX_FIELD(ch3.size);
    NX_FIELD(ch3.bank);
    NX_FIELD(ch3.enable);
    NX_FIELD(ch3.sample);
    NX_FIELD(ch3.length);
    NX_FIELD(ch3.volume);
    NX_FIELD(ch3.rate);
    NX_FIELD(ch3.stop);
    NX_FIELD(ch3.window);
    NX_FIELD(ch3.readable);
    NX_FIELD(ch3.wavedata32);
    NX_FIELD(ch3.nextUpdate);
    NX_FIELD(ch4.envelope.length);
    NX_FIELD(ch4.envelope.duty);
    NX_FIELD(ch4.envelope.stepTime);
    NX_FIELD(ch4.envelope.initialVolume);
    NX_FIELD(ch4.envelope.currentVolume);
    NX_FIELD(ch4.envelope.direction);
    NX_FIELD(ch4.envelope.dead);
    NX_FIELD(ch4.envelope.nextStep);
    NX_FIELD(ch4.ratio);
    NX_FIELD(ch4.frequency);
    NX_FIELD(ch4.power);
    NX_FIELD(ch4.stop);
    NX_FIELD(ch4.length);
    NX_FIELD(ch4.lfsr);
    NX_FIELD(ch4.nSamples);
    NX_FIELD(ch4.samples);
    NX_FIELD(ch4.lastEvent);
    NX_FIELD(ch4.sample);
    NX_FIELD(lastLeft);
    NX_FIELD(lastRight);
    NX_FIELD(capLeft);
    NX_FIELD(capRight);
    NX_FIELD(clock);
    NX_FIELD(volumeRight);
    NX_FIELD(volumeLeft);
    NX_FIELD(ch1Right);
    NX_FIELD(ch2Right);
    NX_FIELD(ch3Right);
    NX_FIELD(ch4Right);
    NX_FIELD(ch1Left);
    NX_FIELD(ch2Left);
    NX_FIELD(ch3Left);
    NX_FIELD(ch4Left);
    NX_FIELD(playingCh1);
    NX_FIELD(playingCh2);
    NX_FIELD(playingCh3);
    NX_FIELD(playingCh4);
    NX_FIELD(frame);
    NX_FIELD(skipFrame);
    NX_FIELD(enable);
#undef NX_FIELD
    return n;
}

// Copyright (c) 2026 Chris Silvertooth. Private frame-boundary rollback format.
- (NSData *)serializeNetplayStateWithError:(NSError **)error
{
    NSData *base=[self serializeStateWithError:error];if(!base)return nil;
    blip_t *left=core->getAudioChannel(core,0),*right=core->getAudioChannel(core,1);
    uint32_t sizes[3]={(uint32_t)base.length,blip_snapshot_size(left),blip_snapshot_size(right)};
    NSMutableData *data=[NSMutableData dataWithLength:512+sizes[0]+sizes[1]+sizes[2]];
    unsigned char *p=data.mutableBytes;memcpy(p,"NXGB0002",8);memcpy(p+8,sizes,12);
    struct GBAAudio *audio=&((struct GBA *)core->board)->audio;
    memcpy(p+20,&audio->clock,4);memcpy(p+24,&audio->lastLeft,2);memcpy(p+26,&audio->lastRight,2);
    if(NXPSGSnapshot(&audio->psg,NULL,NO)>480)return nil;
    NXPSGSnapshot(&audio->psg,p+32,NO);
    memcpy(p+512,base.bytes,base.length);
    if(!blip_snapshot_save(left,p+512+sizes[0],sizes[1]) || !blip_snapshot_save(right,p+512+sizes[0]+sizes[1],sizes[2]))return nil;
    return data;
}
- (BOOL)deserializeNetplayState:(NSData *)data withError:(NSError **)error
{
    if(data.length<512)return NO;const unsigned char *p=data.bytes;uint32_t sizes[3];memcpy(sizes,p+8,12);
    blip_t *left=core->getAudioChannel(core,0),*right=core->getAudioChannel(core,1);
    if(memcmp(p,"NXGB0002",8) || sizes[0]>2*1024*1024 || sizes[1]!=blip_snapshot_size(left) || sizes[2]!=blip_snapshot_size(right) || data.length!=512+sizes[0]+sizes[1]+sizes[2])return NO;
    if(![self deserializeState:[NSData dataWithBytes:p+512 length:sizes[0]] withError:error])return NO;
    struct GBAAudio *audio=&((struct GBA *)core->board)->audio;
    memcpy(&audio->clock,p+20,4);memcpy(&audio->lastLeft,p+24,2);memcpy(&audio->lastRight,p+26,2);
    NXPSGSnapshot(&audio->psg,(unsigned char *)p+32,YES);
    return blip_snapshot_load(left,p+512+sizes[0],sizes[1]) && blip_snapshot_load(right,p+512+sizes[0]+sizes[1],sizes[2]);
}

- (NSData *)serializeStateWithError:(NSError **)outError
{
	struct VFile* vf = VFileMemChunk(nil, 0);
	if (!mCoreSaveStateNamed(core, vf, SAVESTATE_SAVEDATA)) {
		if (outError) {
			*outError = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:nil];
		}
		vf->close(vf);
		return nil;
	}
	size_t size = vf->size(vf);
	void* data = vf->map(vf, size, MAP_READ);
	NSData *nsdata = [NSData dataWithBytes:data length:size];
	vf->unmap(vf, data, size);
	vf->close(vf);
	return nsdata;
}

- (BOOL)deserializeState:(NSData *)state withError:(NSError **)outError
{
	struct VFile* vf = VFileFromConstMemory(state.bytes, state.length);
	if (!mCoreLoadStateNamed(core, vf, SAVESTATE_SAVEDATA)) {
		if (outError) {
			*outError = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:nil];
		}
		vf->close(vf);
		return NO;
	}
	vf->close(vf);
	return YES;
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
	struct VFile* vf = VFileOpen([fileName fileSystemRepresentation], O_CREAT | O_TRUNC | O_RDWR);
	block(mCoreSaveStateNamed(core, vf, 0), nil);
	vf->close(vf);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
	struct VFile* vf = VFileOpen([fileName fileSystemRepresentation], O_RDONLY);
	BOOL ok = mCoreLoadStateNamed(core, vf, 0);
	vf->close(vf);
	if (ok) {
		[_raBridge reset];
	}
	block(ok, nil);
}

#pragma mark - Input

const int GBAMap[] = {
	GBA_KEY_UP,
	GBA_KEY_DOWN,
	GBA_KEY_LEFT,
	GBA_KEY_RIGHT,
	GBA_KEY_A,
	GBA_KEY_B,
	GBA_KEY_L,
	GBA_KEY_R,
	GBA_KEY_START,
	GBA_KEY_SELECT
};

- (oneway void)didPushGBAButton:(OEGBAButton)button forPlayer:(NSUInteger)player
{
	UNUSED(player);
	core->addKeys(core, 1 << GBAMap[button]);
}

- (oneway void)didReleaseGBAButton:(OEGBAButton)button forPlayer:(NSUInteger)player
{
	UNUSED(player);
	core->clearKeys(core, 1 << GBAMap[button]);
}

#pragma mark - Cheats

- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
	code = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	code = [code stringByReplacingOccurrencesOfString:@" " withString:@""];

	NSString *codeId = [code stringByAppendingFormat:@"/%@", type];
	struct mCheatSet* cheatSet = [[cheatSets objectForKey:codeId] pointerValue];
	if (cheatSet) {
		cheatSet->enabled = enabled;
		return;
	}
	struct mCheatDevice* cheats = core->cheatDevice(core);
	cheatSet = cheats->createSet(cheats, [codeId UTF8String]);
	size_t size = mCheatSetsSize(&cheats->cheats);
	if (size) {
		cheatSet->copyProperties(cheatSet, *mCheatSetsGetPointer(&cheats->cheats, size - 1));
	}
	int codeType = GBA_CHEAT_AUTODETECT;
	NSArray *codeSet = [code componentsSeparatedByString:@"+"];
	for (id c in codeSet) {
		mCheatAddLine(cheatSet, [c UTF8String], codeType);
	}
	cheatSet->enabled = enabled;
	[cheatSets setObject:[NSValue valueWithPointer:cheatSet] forKey:codeId];
	mCheatAddSet(cheats, cheatSet);
}

- (NSArray<OEMemoryRegionDescriptor *> *)readableMemoryRegions
{
	const struct mCoreMemoryBlock* blocks = NULL;
	size_t count = core->listMemoryBlocks(core, &blocks);
	NSMutableArray *regions = [NSMutableArray arrayWithCapacity:count];
	for (size_t i = 0; i < count; i++) {
		if (strcmp(blocks[i].shortName, "IWRAM") != 0 &&
		    strcmp(blocks[i].shortName, "EWRAM") != 0) {
			continue;
		}
		size_t size = 0;
		void* memory = core->getMemoryBlock(core, blocks[i].id, &size);
		if (memory && size > 0) {
			NSData *data = [NSData dataWithBytes:memory length:size];
			NSString *name = [NSString stringWithUTF8String:blocks[i].shortName];
			OEMemoryRegionDescriptor *descriptor = [OEMemoryRegionDescriptor
			    descriptorWithName:name
			              address:blocks[i].start
			         addressBytes:4
			                 data:data];
			[regions addObject:descriptor];
		}
	}
	return regions;
}

@end

