// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
// Same-build Snes9x replay probe. No networking or frontend scheduling.
#import <Foundation/Foundation.h>
#import <OpenEmuBase/OpenEmuBase.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#import <OpenGL/gl.h>
#include <stdio.h>
#include <errno.h>

@interface ReplayController : OEGameCoreController
@property(nonatomic, strong) NSURL *root;
@end
@implementation ReplayController
- (NSURL *)supportDirectory { return [self.root URLByAppendingPathComponent:@"Support"]; }
- (NSURL *)biosDirectory { return [self.root URLByAppendingPathComponent:@"BIOS"]; }
- (NSString *)supportDirectoryPath { return self.supportDirectory.path; }
- (NSString *)biosDirectoryPath { return self.biosDirectory.path; }
@end

static BOOL Snapshot(OEGameCore *core, FILE *out, unsigned frame, NSString *dumpPath) {
    NSError *error = nil;
    NSData *state = [core serializeStateWithError:&error];
    if (!state.length || state.length > UINT32_MAX) {
        fprintf(stderr, "snapshot failed at %u: %s\n", frame, error.description.UTF8String);
        return NO;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(state.bytes, (CC_LONG)state.length, digest);
    if (fprintf(out, "%u %lu ", frame, (unsigned long)state.length) < 0) return NO;
    for (unsigned i = 0; i < sizeof(digest); ++i)
        if (fprintf(out, "%02x", digest[i]) < 0) return NO;
    if (fputc('\n', out) == EOF) return NO;
    if (dumpPath && ![state writeToFile:dumpPath options:NSDataWritingAtomic error:&error]) {
        fprintf(stderr, "state dump failed: %s\n", error.description.UTF8String);
        return NO;
    }
    return YES;
}

// Capture the SNES RGB565 framebuffer without changing core execution or state.
static BOOL Capture(OEGameCore *core, const void *video, NSString *directory, unsigned frame) {
    OEIntRect screen = core.screenRect;
    OEIntSize size = core.bufferSize;
    if (!video || screen.size.width <= 0 || screen.size.height <= 0 ||
        screen.origin.x < 0 || screen.origin.y < 0 ||
        screen.origin.x + screen.size.width > size.width ||
        screen.origin.y + screen.size.height > size.height ||
        core.pixelFormat != GL_RGB || core.pixelType != GL_UNSIGNED_SHORT_5_6_5) return NO;
    NSBitmapImageRep *image = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:screen.size.width pixelsHigh:screen.size.height bitsPerSample:8 samplesPerPixel:3
        hasAlpha:NO isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    if (!image) return NO;
    for (NSInteger y = 0; y < screen.size.height; ++y) {
        const uint16_t *row = (const uint16_t *)((const uint8_t *)video + (screen.origin.y + y) * core.bytesPerRow);
        uint8_t *out = image.bitmapData + y * image.bytesPerRow;
        for (NSInteger x = 0; x < screen.size.width; ++x) {
            uint16_t pixel = row[screen.origin.x + x];
            unsigned r = (pixel >> 11) & 31, g = (pixel >> 5) & 63, b = pixel & 31;
            out[x*3] = (r << 3) | (r >> 2);
            out[x*3+1] = (g << 2) | (g >> 4);
            out[x*3+2] = (b << 3) | (b >> 2);
        }
    }
    NSData *png = [image representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"frame-%06u.png", frame]];
    NSError *error = nil;
    return [png writeToFile:path options:NSDataWritingWithoutOverwriting error:&error];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 5 && argc != 6) {
            fprintf(stderr, "usage: snes-replay CORE ROM TRACE OUTPUT [DUMP_FRAME]\n");
            return 2;
        }
        long dumpFrame = -1;
        if (argc == 6) {
            char *end = NULL;
            errno = 0;
            dumpFrame = strtol(argv[5], &end, 10);
            if (errno || *end || dumpFrame < 0 || dumpFrame > 10000000) return 2;
        }
        NSString *captureDir = NSProcessInfo.processInfo.environment[@"SNES_REPLAY_CAPTURE_DIR"];
        NSString *captureFrames = NSProcessInfo.processInfo.environment[@"SNES_REPLAY_CAPTURE_FRAMES"];
        NSMutableSet<NSNumber *> *captures = [NSMutableSet set];
        if (captureDir.length || captureFrames.length) {
            if (!captureDir.length || !captureFrames.length) return 2;
            for (NSString *part in [captureFrames componentsSeparatedByString:@","]) {
                NSScanner *scanner = [NSScanner scannerWithString:part];
                long long frame;
                if (![scanner scanLongLong:&frame] || !scanner.isAtEnd || frame < 1 || frame > 10000000) return 2;
                [captures addObject:@(frame)];
            }
            if (![NSFileManager.defaultManager createDirectoryAtPath:captureDir withIntermediateDirectories:YES
                attributes:nil error:nil]) return 2;
        }
        NSString *output = @(argv[4]);
        NSString *dump = [output stringByAppendingString:@".state"];
        FILE *trace = fopen(argv[3], "r");
        // Never overwrite earlier evidence accidentally.
        FILE *out = fopen(argv[4], "wx");
        if (!trace || !out) { perror("open replay files"); if(trace) fclose(trace); if(out) fclose(out); return 2; }
        ReplayController *controller = nil;
        OEGameCore *core = nil;
        int result = 1;
        @try {
            NSBundle *bundle = [NSBundle bundleWithPath:@(argv[1])];
            NSError *error = nil;
            if (![bundle loadAndReturnError:&error]) {
                fprintf(stderr, "load core: %s\n", error.description.UTF8String);
                return 1;
            }
            controller = [[ReplayController alloc] initWithBundle:bundle];
            controller.root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                [@"snes-replay-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
            for (NSString *sub in @[@"Support", @"BIOS"])
                if (![NSFileManager.defaultManager createDirectoryAtURL:[controller.root URLByAppendingPathComponent:sub]
                    withIntermediateDirectories:YES attributes:nil error:&error]) return 1;
            core = [controller newGameCore];
            core.owner = controller;
            core.systemIdentifier = @"openemu.system.snes";
            SEL push = NSSelectorFromString(@"didPushSNESButton:forPlayer:");
            SEL release = NSSelectorFromString(@"didReleaseSNESButton:forPlayer:");
            if (!core || ![core respondsToSelector:push] || ![core respondsToSelector:release]) return 1;
            if (![core loadFileAtPath:@(argv[2]) error:&error]) {
                fprintf(stderr, "load ROM: %s\n", error.description.UTF8String); return 1;
            }
            __block BOOL ready = NO;
            [core setupEmulationWithCompletionHandler:^{ ready = YES; }];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
            while (!ready && deadline.timeIntervalSinceNow > 0)
                [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            if (!ready || !Snapshot(core, out, 0, dumpFrame == 0 ? dump : nil)) return 1;
            unsigned expected = 1;
            char line[256];
            unsigned previous[2] = {0, 0};
            while (fgets(line, sizeof(line), trace)) {
                @autoreleasepool {
                    unsigned frame, masks[2]; char extra;
                    if (sscanf(line, "%u %u %u %c", &frame, &masks[0], &masks[1], &extra) != 3 ||
                        frame != expected || masks[0] > 4095 || masks[1] > 4095 || frame > 10000000) {
                        fprintf(stderr, "invalid trace row at frame %u\n", expected); return 2;
                    }
                    // Bits follow OESNESButton order; controller numbers are one-based.
                    for (unsigned p = 0; p < 2; ++p) {
                        unsigned changes = previous[p] ^ masks[p];
                        for (unsigned button = 0; button < 12; ++button)
                            if (changes & (1u << button))
                                ((void (*)(id, SEL, NSInteger, NSUInteger))objc_msgSend)(core,
                                    (masks[p] & (1u << button)) ? push : release, button, p + 1);
                        previous[p] = masks[p];
                    }
                    // This Snes9x implementation explicitly accepts a null hint for its owned buffer.
                    const void *video = ((const void *(*)(id, SEL, void *))objc_msgSend)(core,
                        @selector(getVideoBufferWithHint:), NULL);
                    [core executeFrame];
                    for (NSUInteger i = 0; i < core.audioBufferCount; ++i) {
                        OERingBuffer *ring = (OERingBuffer *)[core audioBufferAtIndex:i];
                        ring.anticipatesUnderflow = NO;
                        NSUInteger bytes = ring.availableBytes;
                        if (bytes) { NSMutableData *audio = [NSMutableData dataWithLength:bytes]; [ring read:audio.mutableBytes maxLength:bytes]; }
                    }
                    if (!Snapshot(core, out, frame, dumpFrame == frame ? dump : nil)) return 1;
                    if ([captures containsObject:@(frame)]) {
                        if (!Capture(core, video, captureDir, frame)) {
                            fprintf(stderr, "capture failed at frame %u\n", frame); return 1;
                        }
                        [captures removeObject:@(frame)];
                    }
                    ++expected;
                    if (dumpFrame >= 0 && frame >= dumpFrame) break;
                }
            }
            if (captures.count || ferror(trace) || expected == 1 || (dumpFrame >= 0 && expected <= dumpFrame)) return 2;
            result = 0;
        } @catch (NSException *exception) {
            fprintf(stderr, "replay exception: %s\n", exception.description.UTF8String);
        } @finally {
            if (core) [core stopEmulationWithCompletionHandler:^{}];
            if (controller.root) [NSFileManager.defaultManager removeItemAtURL:controller.root error:nil];
            fclose(trace);
            if (fclose(out) != 0) result = 1;
        }
        return result;
    }
}
