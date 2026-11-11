// Copyright (c) 2018, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#import "NSUserDefaults+OpenEmuSDK.h"


// Auxiliary executables can have an embedded Info.plist. NSBundle may cache
// that dictionary under the containing application's URL. Read the host's real
// plist directly so the core process and GUI always use the same configuration.
static NSURL *OEHostConfigurationURL(void)
{
    NSURL *url = NSBundle.mainBundle.executableURL ?: NSBundle.mainBundle.bundleURL;
    for (NSUInteger depth = 0; depth < 24 && url.path.length > 1; ++depth) {
        if ([url.pathExtension isEqualToString:@"app"]) {
            NSURL *infoURL = [url URLByAppendingPathComponent:@"Contents/Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:infoURL];
            if (info[@"OEApplicationSupportFolder"] != nil) return infoURL;
        }
        url = url.URLByDeletingLastPathComponent;
    }
    return nil;
}

static NSDictionary *OEHostConfiguration(void)
{
    NSURL *url = OEHostConfigurationURL();
    return url ? [NSDictionary dictionaryWithContentsOfURL:url] : NSBundle.mainBundle.infoDictionary;
}

NSBundle *OEHostApplicationBundle(void)
{
    NSURL *url = OEHostConfigurationURL();
    return url ? [NSBundle bundleWithURL:url.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent] : NSBundle.mainBundle;
}

NSString *OEApplicationSupportFolderName(void)
{
    id value = OEHostConfiguration()[@"OEApplicationSupportFolder"];
    if ([value isKindOfClass:NSString.class] && [value length] > 0 &&
        ![value isEqualToString:@"."] && ![value isEqualToString:@".."] &&
        [value rangeOfString:@"/"].location == NSNotFound)
        return value;
    return @"OpenEmu"; // Compatibility for standalone SDK consumers.
}

NSURL *OEApplicationSupportDirectoryURL(void)
{
    NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    if (!base) base = [NSFileManager.defaultManager.homeDirectoryForCurrentUser URLByAppendingPathComponent:@"Library/Application Support" isDirectory:YES];
    return [base URLByAppendingPathComponent:OEApplicationSupportFolderName() isDirectory:YES];
}

NSString *OEApplicationPreferencesDomain(void)
{
    return OEHostConfiguration()[@"CFBundleIdentifier"] ?: @"org.openemu.OpenEmu";
}

@implementation NSUserDefaults (OpenEmuSDK)

+ (instancetype)oe_applicationUserDefaults
{
    NSBundle *thisBundle = [NSBundle mainBundle];
    if ([[thisBundle bundleIdentifier] isEqualToString:OEApplicationPreferencesDomain()])
        return [[self class] standardUserDefaults];
    return [[[self class] alloc] initWithSuiteName:OEApplicationPreferencesDomain()];
}

+ (NSUserDefaults *)oe_application
{
    return [self oe_applicationUserDefaults];
}

@end
