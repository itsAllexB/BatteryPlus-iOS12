// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// batteryplusd: the Unplug Reminder.
//
// Runs as mobile, reads the battery level and the power connection from IOPMPowerSource when
// the system posts a power-source notification, and shows one alert per charging session when the
// level reaches the chosen percentage while iPad is connected. It never writes to IOKit and never
// changes how the iPad charges, so stopping or removing it cannot affect charging.
//
//   batteryplusd                 run (launchd)
//   batteryplusd status          print the inputs and the current decision state
//   batteryplusd simulate LEVEL  read "capacity connected(0/1)" lines from stdin, print decisions
//   batteryplusd test-alert      show the reminder alert once (for screenshots)

#import <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
#include <notify.h>

#define kBPDomain CFSTR("com.itsallexb.batteryplus")
#define kBPNotification "com.itsallexb.batteryplus/prefschanged"

typedef struct {
    BOOL armed;  // seen below the level while connected in this session
    BOOL fired;  // already reminded in this session (until unplugged)
} BPState;

// One step of the reminder. A session starts when power is connected and ends when it is
// removed. The alert fires once per session, on the upward crossing of the level: plugging in
// above the level does not alert, and a level that wobbles around the threshold alerts once.
static BOOL BPStep(BPState *st, BOOL enabled, NSInteger level, NSInteger capacity, BOOL connected) {
    if (!connected) { st->armed = NO; st->fired = NO; return NO; }
    if (capacity < level) { st->armed = YES; return NO; }
    BOOL fire = enabled && st->armed && !st->fired;
    if (fire) st->fired = YES;
    st->armed = NO;
    return fire;
}

static BOOL BPReadBattery(NSInteger *capacity, BOOL *connected) {
    io_service_t s = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPMPowerSource"));
    if (!s) return NO;
    CFMutableDictionaryRef p = NULL;
    BOOL ok = NO;
    if (IORegistryEntryCreateCFProperties(s, &p, kCFAllocatorDefault, 0) == KERN_SUCCESS && p) {
        NSDictionary *d = (__bridge_transfer NSDictionary *)p;
        NSNumber *cap = d[@"CurrentCapacity"], *ext = d[@"ExternalConnected"];
        if ([cap isKindOfClass:[NSNumber class]] && [ext isKindOfClass:[NSNumber class]]) {
            *capacity = cap.integerValue;
            *connected = ext.boolValue;
            ok = YES;
        }
    }
    IOObjectRelease(s);
    return ok;
}

static BOOL gEnabled;
static NSInteger gLevel = 80;

static void BPLoadPrefs(void) {
    CFPreferencesAppSynchronize(kBPDomain);
    CFPropertyListRef e = CFPreferencesCopyAppValue(CFSTR("reminderEnabled"), kBPDomain);
    CFPropertyListRef l = CFPreferencesCopyAppValue(CFSTR("reminderLevel"), kBPDomain);
    gEnabled = e && CFGetTypeID(e) == CFBooleanGetTypeID() && CFBooleanGetValue(e);
    NSInteger level = 80;
    if (l && CFGetTypeID(l) == CFNumberGetTypeID()) CFNumberGetValue(l, kCFNumberNSIntegerType, &level);
    gLevel = (level >= 50 && level <= 100) ? level : 80;
    if (e) CFRelease(e);
    if (l) CFRelease(l);
}

// The alert lives as long as its CFUserNotification object, so keep it until it is answered
// (or until the next reminder replaces it).
static CFUserNotificationRef gNote;
static CFRunLoopSourceRef gNoteSource;

static void BPNoteDone(CFUserNotificationRef note, CFOptionFlags flags) {
    if (note != gNote) return;
    if (gNoteSource) { CFRunLoopRemoveSource(CFRunLoopGetMain(), gNoteSource, kCFRunLoopCommonModes); CFRelease(gNoteSource); gNoteSource = NULL; }
    CFRelease(gNote); gNote = NULL;
}

static BOOL BPShowAlert(NSInteger level) {
    if (gNote) { CFUserNotificationCancel(gNote); BPNoteDone(gNote, 0); }
    NSString *title = [NSString stringWithFormat:@"Battery at %ld%%", (long)level];
    NSString *msg = [NSString stringWithFormat:@"iPad has charged to %ld%%. Unplug it now to help preserve battery lifespan.\n\nYou can turn this reminder off in Settings > Battery > Charging.", (long)level];
    NSDictionary *d = @{(__bridge NSString *)kCFUserNotificationAlertHeaderKey: title,
                        (__bridge NSString *)kCFUserNotificationAlertMessageKey: msg,
                        (__bridge NSString *)kCFUserNotificationDefaultButtonTitleKey: @"OK"};
    SInt32 err = 0;
    gNote = CFUserNotificationCreate(kCFAllocatorDefault, 0, kCFUserNotificationNoteAlertLevel, &err, (__bridge CFDictionaryRef)d);
    if (!gNote) { NSLog(@"batteryplusd: alert failed (%d)", (int)err); return NO; }
    gNoteSource = CFUserNotificationCreateRunLoopSource(kCFAllocatorDefault, gNote, BPNoteDone, 0);
    if (gNoteSource) CFRunLoopAddSource(CFRunLoopGetMain(), gNoteSource, kCFRunLoopCommonModes);
    return YES;
}

static BPState gState;

static void BPEvaluate(const char *why) {
    NSInteger cap; BOOL conn;
    if (!BPReadBattery(&cap, &conn)) return;
    if (BPStep(&gState, gEnabled, gLevel, cap, conn)) {
        NSLog(@"batteryplusd: %ld%% reached while connected (%s), showing reminder", (long)cap, why);
        BPShowAlert(gLevel);
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc >= 2 && !strcmp(argv[1], "test-alert")) {
            BPLoadPrefs();
            if (!BPShowAlert(gLevel)) return 1;
            CFOptionFlags flags = 0;
            CFUserNotificationReceiveResponse(gNote, 120, &flags); // wait until it is answered
            return 0;
        }
        if (argc >= 2 && !strcmp(argv[1], "status")) {
            BPLoadPrefs();
            NSInteger cap = -1; BOOL conn = NO;
            BOOL ok = BPReadBattery(&cap, &conn);
            printf("enabled=%d level=%ld read=%d capacity=%ld connected=%d\n", gEnabled, (long)gLevel, ok, (long)cap, conn);
            return 0;
        }
        if (argc >= 3 && !strcmp(argv[1], "simulate")) {
            BPState st = {0};
            NSInteger level = atoi(argv[2]);
            char line[128];
            while (fgets(line, sizeof line, stdin)) {
                int cap, conn;
                if (sscanf(line, "%d %d", &cap, &conn) != 2) continue;
                BOOL fire = BPStep(&st, YES, level, cap, conn != 0);
                printf("cap=%3d connected=%d -> %s\n", cap, conn, fire ? "ALERT" : "-");
            }
            return 0;
        }

        BPLoadPrefs();
        // Start state: if iPad is already connected and at or above the level, wait for the next
        // session instead of alerting right away (daemon restarts must not alert either).
        NSInteger cap; BOOL conn;
        if (BPReadBattery(&cap, &conn)) BPStep(&gState, NO, gLevel, cap, conn);

        dispatch_queue_t q = dispatch_get_main_queue();
        int token;
        notify_register_dispatch(kBPNotification, &token, q, ^(int t) {
            BPLoadPrefs();
            // A changed level starts from the current state, like a fresh start.
            NSInteger c; BOOL x;
            if (BPReadBattery(&c, &x)) { gState = (BPState){0}; BPStep(&gState, NO, gLevel, c, x); }
        });
        // Percentage changes and plug/unplug events (IOPowerSources notify names).
        notify_register_dispatch("com.apple.system.powersources.percent", &token, q, ^(int t) { BPEvaluate("percent"); });
        notify_register_dispatch("com.apple.system.powersources.attach", &token, q, ^(int t) { BPEvaluate("attach"); });
        notify_register_dispatch("com.apple.system.powersources.source", &token, q, ^(int t) { BPEvaluate("source"); });
        CFRunLoopRun();
    }
}
