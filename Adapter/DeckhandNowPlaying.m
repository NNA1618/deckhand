// Deckhand's now playing adapter.
//
// Since macOS 15.4 the private MediaRemote framework answers only to Apple-signed processes,
// so Deckhand runs this library inside Apple's own /usr/bin/perl (see now-playing.pl), which
// MediaRemote trusts. The library registers for MediaRemote's notifications and writes the
// system Now Playing state to stdout as one JSON object per line. It reads commands from stdin,
// one per line: "toggle", "play", "pause", "next", "previous". It exits when stdin closes, so it
// never outlives Deckhand.
//
// Idle when nothing changes: no timers, only notifications and the stdin read source.
//
// Lines written:
//   {"type":"hello","version":1}
//   {"type":"state","active":false}
//   {"type":"state","active":true,"playing":true,"title":"…","artist":"…","album":"…",
//    "duration":215.0,"elapsed":12.5,"rate":1.0,"timestamp":1762790000.0,"bundle":"com.spotify.client",
//    "artwork":"<base64>"}       artwork only when it changed; "" means the track has none
//   {"type":"error","message":"…"}  then the process exits with status 1
//
// The approach (a platform binary loading a small library) follows the idea of the
// mediaremote-adapter project by ungive; this file is an independent implementation.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>
#include <stdio.h>
#include <libproc.h>

typedef void (*RegisterFn)(dispatch_queue_t);
typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*ClientStringFn)(id);
typedef void (*GetPIDFn)(dispatch_queue_t, void (^)(int));
typedef Boolean (*SendCommandFn)(int, CFDictionaryRef);

// MRMediaRemoteCommand values
enum { kCommandPlay = 0, kCommandPause = 1, kCommandToggle = 2, kCommandNext = 4, kCommandPrevious = 5 };

static RegisterFn mrRegister;
static GetInfoFn mrGetInfo;
static GetIsPlayingFn mrGetIsPlaying;
static GetClientFn mrGetClient;
static ClientStringFn mrClientBundle;
static ClientStringFn mrClientParentBundle;
static GetPIDFn mrGetPID;
static SendCommandFn mrSendCommand;

static dispatch_queue_t queue;
static BOOL refreshing;
static BOOL refreshAgain;
static NSString *lastLine;
static NSData *lastArtwork;
static BOOL artworkSent;
static NSString *lastTrack;
static dispatch_source_t commandSource;
static dispatch_source_t parentSource;

static void emit(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!json) return;
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    const char *bytes = line.bytes;
    size_t left = line.length;
    while (left > 0) {
        ssize_t n = write(STDOUT_FILENO, bytes, left);
        if (n <= 0) exit(0);  // Deckhand is gone
        bytes += n;
        left -= (size_t)n;
    }
}

static void fail(NSString *message) {
    emit(@{@"type": @"error", @"message": message});
    exit(1);
}

static NSString *stringValue(NSDictionary *info, NSString *key) {
    id value = info[key];
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static NSNumber *numberValue(NSDictionary *info, NSString *key) {
    id value = info[key];
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

static void publish(NSDictionary *info, BOOL playing, NSString *bundle) {
    NSString *title = stringValue(info, @"kMRMediaRemoteNowPlayingInfoTitle");
    if (info == nil || (title.length == 0 && bundle.length == 0)) {
        NSDictionary *idle = @{@"type": @"state", @"active": @NO};
        NSString *key = idle.description;
        if (![key isEqualToString:lastLine]) {
            lastLine = key;
            lastArtwork = nil;
            lastTrack = nil;
            artworkSent = NO;
            emit(idle);
        }
        return;
    }
    NSMutableDictionary *state = [@{@"type": @"state", @"active": @YES, @"playing": @(playing)} mutableCopy];
    state[@"title"] = title;
    state[@"artist"] = stringValue(info, @"kMRMediaRemoteNowPlayingInfoArtist");
    state[@"album"] = stringValue(info, @"kMRMediaRemoteNowPlayingInfoAlbum");
    state[@"bundle"] = bundle ?: @"";
    NSNumber *duration = numberValue(info, @"kMRMediaRemoteNowPlayingInfoDuration");
    if (duration) state[@"duration"] = duration;
    NSNumber *elapsed = numberValue(info, @"kMRMediaRemoteNowPlayingInfoElapsedTime");
    if (elapsed) state[@"elapsed"] = elapsed;
    NSNumber *rate = numberValue(info, @"kMRMediaRemoteNowPlayingInfoPlaybackRate");
    if (rate) state[@"rate"] = rate;
    id timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    if ([timestamp isKindOfClass:[NSDate class]]) state[@"timestamp"] = @([(NSDate *)timestamp timeIntervalSince1970]);

    // MediaRemote leaves the artwork out of some updates for the same track: keep the last one then,
    // and say "none" only when the track itself changed.
    NSString *track = [NSString stringWithFormat:@"%@\x1f%@\x1f%@\x1f%@", title, state[@"artist"], state[@"album"], state[@"bundle"]];
    id artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    NSData *art = [artwork isKindOfClass:[NSData class]] && [(NSData *)artwork length] > 0 ? artwork : nil;
    BOOL sameTrack = [track isEqualToString:lastTrack];
    BOOL artChanged = art ? ![art isEqualToData:lastArtwork] : (!sameTrack && (lastArtwork != nil || !artworkSent));
    lastTrack = track;

    NSString *key = state.description;
    if ([key isEqualToString:lastLine] && !artChanged) return;
    lastLine = key;
    if (artChanged) {
        lastArtwork = art;
        artworkSent = YES;
        state[@"artwork"] = art ? [art base64EncodedStringWithOptions:0] : @"";
    }
    emit(state);
}

/// The app bundle that contains a process, for clients that don't name their bundle.
static NSString *bundleOfProcess(int pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (pid <= 0 || proc_pidpath(pid, path, sizeof path) <= 0) return @"";
    NSString *executable = [NSString stringWithUTF8String:path];
    NSRange app = [executable rangeOfString:@".app/"];
    if (app.location == NSNotFound) return @"";
    NSString *bundlePath = [executable substringToIndex:app.location + 4];
    return [NSBundle bundleWithPath:bundlePath].bundleIdentifier ?: @"";
}

static void bundleOfClient(void (^done)(NSString *)) {
    if (mrGetClient && (mrClientParentBundle || mrClientBundle)) {
        mrGetClient(queue, ^(id client) {
            NSString *bundle = nil;
            if (client && mrClientParentBundle) bundle = (__bridge NSString *)mrClientParentBundle(client);
            if (bundle.length == 0 && client && mrClientBundle) bundle = (__bridge NSString *)mrClientBundle(client);
            if (bundle.length > 0 || !mrGetPID) { done(bundle ?: @""); return; }
            mrGetPID(queue, ^(int pid) { done(bundleOfProcess(pid)); });
        });
    } else if (mrGetPID) {
        mrGetPID(queue, ^(int pid) { done(bundleOfProcess(pid)); });
    } else {
        done(@"");
    }
}

/// One refresh at a time; notifications that arrive meanwhile ask for one more afterwards.
static void refresh(void) {
    if (refreshing) { refreshAgain = YES; return; }
    refreshing = YES;
    mrGetInfo(queue, ^(CFDictionaryRef raw) {
        NSDictionary *info = raw ? [(__bridge NSDictionary *)raw copy] : nil;
        mrGetIsPlaying(queue, ^(Boolean playing) {
            bundleOfClient(^(NSString *bundle) {
                publish(info, playing, bundle);
                refreshing = NO;
                if (refreshAgain) { refreshAgain = NO; refresh(); }
            });
        });
    });
}

static void handleCommand(NSString *command) {
    int code;
    if ([command isEqualToString:@"toggle"]) code = kCommandToggle;
    else if ([command isEqualToString:@"play"]) code = kCommandPlay;
    else if ([command isEqualToString:@"pause"]) code = kCommandPause;
    else if ([command isEqualToString:@"next"]) code = kCommandNext;
    else if ([command isEqualToString:@"previous"]) code = kCommandPrevious;
    else return;
    if (mrSendCommand) mrSendCommand(code, NULL);
}

static void readCommands(void) {
    static NSMutableData *pending;
    pending = [NSMutableData data];
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, queue);
    dispatch_source_set_event_handler(source, ^{
        char buffer[512];
        ssize_t n = read(STDIN_FILENO, buffer, sizeof buffer);
        if (n <= 0) exit(0);  // stdin closed: Deckhand quit or stopped us
        [pending appendBytes:buffer length:(NSUInteger)n];
        while (true) {
            NSRange newline = [pending rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0
                                             range:NSMakeRange(0, pending.length)];
            if (newline.location == NSNotFound) break;
            NSData *lineData = [pending subdataWithRange:NSMakeRange(0, newline.location)];
            [pending replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
            NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
            handleCommand([line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
        }
        if (pending.length > 4096) pending.length = 0;
    });
    dispatch_resume(source);
    commandSource = source;  // kept for the life of the process
}

/// Exits when the process that started us does, even if stdin somehow stays open.
static void watchParent(void) {
    pid_t parent = getppid();
    if (parent <= 1) return;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)parent, DISPATCH_PROC_EXIT, queue);
    dispatch_source_set_event_handler(source, ^{ exit(0); });
    dispatch_resume(source);
    parentSource = source;
    if (getppid() != parent) exit(0);
}

static NSString *notificationName(void *handle, const char *symbol) {
    CFStringRef *value = dlsym(handle, symbol);
    if (value && *value) return (__bridge NSString *)*value;
    return [NSString stringWithUTF8String:symbol];
}

/// The entry point the Perl launcher calls. Never returns.
__attribute__((visibility("default")))
void deckhand_now_playing_main(void) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_DFL);
        void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (!handle) fail([NSString stringWithFormat:@"dlopen failed: %s", dlerror()]);
        mrRegister = (RegisterFn)dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
        mrGetInfo = (GetInfoFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
        mrGetIsPlaying = (GetIsPlayingFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        mrGetClient = (GetClientFn)dlsym(handle, "MRMediaRemoteGetNowPlayingClient");
        mrClientBundle = (ClientStringFn)dlsym(handle, "MRNowPlayingClientGetBundleIdentifier");
        mrClientParentBundle = (ClientStringFn)dlsym(handle, "MRNowPlayingClientGetParentAppBundleIdentifier");
        mrGetPID = (GetPIDFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
        mrSendCommand = (SendCommandFn)dlsym(handle, "MRMediaRemoteSendCommand");
        if (!mrRegister || !mrGetInfo || !mrGetIsPlaying) fail(@"MediaRemote functions not found");

        queue = dispatch_queue_create("deckhand.now-playing", DISPATCH_QUEUE_SERIAL);
        NSArray *names = @[
            notificationName(handle, "kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            notificationName(handle, "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
            notificationName(handle, "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
            notificationName(handle, "kMRMediaRemoteNowPlayingApplicationClientStateDidChange"),
        ];
        for (NSString *name in names) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                                                        usingBlock:^(NSNotification *note) {
                (void)note;
                dispatch_async(queue, ^{ refresh(); });
            }];
        }
        mrRegister(queue);
        emit(@{@"type": @"hello", @"version": @1});
        dispatch_async(queue, ^{ refresh(); });
        readCommands();
        watchParent();
    }
    dispatch_main();
}
