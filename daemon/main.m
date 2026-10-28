// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// batteryplusd: the Unplug Reminder and Automatic Low Power Mode.
//
// Runs as mobile and reads the battery level and the power connection from IOPMPowerSource when
// the system posts a power-source notification. It never writes to IOKit and never changes how
// the iPad charges, so stopping or removing it cannot affect charging.
//
// Unplug Reminder: one alert per charging session when the level reaches the chosen percentage
// while iPad is connected.
//
// Low Power Mode, automatic and manual:
//   - Automatic (Settings > Battery > Low Power Mode, off by default): when the battery drops to the
//     chosen level (5, 10, 15 or 20%), batteryplusd turns Low Power Mode on through CoreDuet's
//     battery saver, the same call Settings and Control Center make. It turns on once per
//     discharge: turned off below the level, it stays off until the battery has been above the
//     level again. Turning Automatic on, or choosing a new level, at or below the level turns it on
//     right away; a daemon restart never does.
//   - What Automatic turned on, batteryplusd turns off at 80% (also if Automatic was turned off in
//     the meantime), then posts com.apple.system.batterysavermode.auto_disabled so PowerUIAgent
//     shows iOS's own "Low Power Mode Turned Off" notification. Turning Low Power Mode off and on
//     again by hand makes it manual.
//   - Manual (Settings, Control Center, Siri, the low battery alert): stays on until you turn it off.
//     iOS itself (contextstored, CDBatterySaverDaemon -autoDisableCheck) would turn it off at 80%.
//     Its threshold is the autoDisableThreshold preference (default 80) in mobile's
//     com.apple.coreduetd.batterysaver domain, reread when com.apple.coreduetd.batterysaver.prefs is
//     posted. While batteryplusd runs it is 101, which the battery never reaches. On removal and
//     upgrade prerm stops batteryplusd (launchctl unload, which on iOS doesn't send SIGTERM) and runs
//     "batteryplusd restore", which deletes the preference so iOS's 80% comes back; a SIGTERM does the
//     same. After a reboot, until the jailbreak runs again, the 101 stays and nothing turns Low Power
//     Mode off at 80%.
//
//   batteryplusd                       run (launchd)
//   batteryplusd status                print the inputs and the current decision state
//   batteryplusd simulate LEVEL        read "capacity connected(0/1)" lines from stdin, print reminder decisions
//   batteryplusd simulate-lpm LEVEL    read "capacity lowpower(0/1)" lines from stdin, print Low Power Mode decisions
//   batteryplusd test-alert            show the reminder alert once (for screenshots)
//   batteryplusd restore               give iOS its own 80% turn-off back (prerm, after stopping the daemon)

#import <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
#include <notify.h>
#include <dlfcn.h>

#define kBPDomain CFSTR("com.itsallexb.batteryplus")
#define kBPNotification "com.itsallexb.batteryplus/prefschanged"
#define kBPSaverDomain CFSTR("com.apple.coreduetd.batterysaver")
#define kBPSaverPrefsNotification "com.apple.coreduetd.batterysaver.prefs"
#define kBPLowPowerNotification "com.apple.system.batterysavermode"
#define kBPAutoDisabledNotification "com.apple.system.batterysavermode.auto_disabled"
#define kBPAutoOffLevel 80

@interface _CDBatterySaver : NSObject
+ (instancetype)batterySaver;
- (void)setPowerMode:(long long)mode fromSource:(NSString *)source withCompletion:(void (^)(BOOL ok, NSError *error))completion;
@end

#pragma mark - Unplug Reminder

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

#pragma mark - Automatic Low Power Mode

typedef struct {
    BOOL armed;   // the battery was above the level since Low Power Mode was last turned on automatically
    BOOL session; // the current Low Power Mode was turned on by batteryplusd
    BOOL pending; // asked to turn it on, and iOS hasn't reported it on yet
} BPAutoState;

typedef enum { BPAutoNothing, BPAutoTurnOn, BPAutoTurnOff } BPAutoAction;

// One step of Automatic Low Power Mode (see the top of this file). A session is Low Power Mode that
// batteryplusd turned on; it ends when Low Power Mode goes off, whoever turns it off.
static BPAutoAction BPAutoStep(BPAutoState *st, BOOL enabled, NSInteger level, NSInteger capacity, BOOL lowPower) {
    if (lowPower) st->pending = NO;
    else if (!st->pending) st->session = NO;
    if (capacity > level) st->armed = YES;
    if (lowPower && st->session && capacity >= kBPAutoOffLevel) { st->session = NO; return BPAutoTurnOff; }
    if (enabled && !lowPower && !st->pending && st->armed && capacity <= level) { st->armed = NO; st->session = st->pending = YES; return BPAutoTurnOn; }
    return BPAutoNothing;
}

#pragma mark - Inputs

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

static BOOL BPReadLowPower(void) {
    int t;
    uint64_t v = 0;
    if (notify_register_check(kBPLowPowerNotification, &t) == NOTIFY_STATUS_OK) {
        notify_get_state(t, &v);
        notify_cancel(t);
    }
    return v != 0;
}

static BOOL gEnabled, gAutoEnabled;
static NSInteger gLevel = 80, gAutoLevel = 20;

static BOOL BPPrefBool(CFStringRef key) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, kBPDomain);
    BOOL r = v && CFGetTypeID(v) == CFBooleanGetTypeID() && CFBooleanGetValue(v);
    if (v) CFRelease(v);
    return r;
}

static NSInteger BPPrefInt(CFStringRef key, NSInteger def, NSInteger min, NSInteger max) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, kBPDomain);
    NSInteger r = def;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberNSIntegerType, &r);
    if (v) CFRelease(v);
    return (r >= min && r <= max) ? r : def;
}

static void BPLoadPrefs(void) {
    CFPreferencesAppSynchronize(kBPDomain);
    gEnabled = BPPrefBool(CFSTR("reminderEnabled"));
    gLevel = BPPrefInt(CFSTR("reminderLevel"), 80, 50, 100);
    gAutoEnabled = BPPrefBool(CFSTR("lpmAuto"));
    gAutoLevel = BPPrefInt(CFSTR("lpmAutoLevel"), 20, 5, 20);
}

// The session survives daemon restarts (upgrades, KeepAlive), so it is kept in the preferences.
static void BPSaveSession(BOOL session) {
    CFPreferencesSetAppValue(CFSTR("lpmAutoActive"), session ? kCFBooleanTrue : NULL, kBPDomain);
    CFPreferencesAppSynchronize(kBPDomain);
}

// iOS's own 80% turn-off (see the top of this file): off while batteryplusd runs. contextstored
// runs as mobile, so this is mobile's preference, also when run as root (by prerm).
static CFStringRef BPSaverUser(void) {
    return getuid() == 0 ? CFSTR("mobile") : kCFPreferencesCurrentUser;
}

static void BPSetSystemAutoOff(BOOL systemAutoOff) {
    CFPreferencesSynchronize(kBPSaverDomain, BPSaverUser(), kCFPreferencesAnyHost);
    CFPropertyListRef cur = CFPreferencesCopyValue(CFSTR("autoDisableThreshold"), kBPSaverDomain, BPSaverUser(), kCFPreferencesAnyHost);
    BOOL isOurs = NO;
    if (cur && CFGetTypeID(cur) == CFNumberGetTypeID()) { int i = 0; CFNumberGetValue(cur, kCFNumberIntType, &i); isOurs = i == 101; }
    BOOL present = cur != NULL;
    if (cur) CFRelease(cur);
    if (systemAutoOff) {
        if (!isOurs) return; // nothing set, or a value that isn't ours
        CFPreferencesSetValue(CFSTR("autoDisableThreshold"), NULL, kBPSaverDomain, BPSaverUser(), kCFPreferencesAnyHost);
    } else {
        if (isOurs) return;
        if (present) NSLog(@"batteryplusd: replacing an autoDisableThreshold that isn't ours");
        int v = 101;
        CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
        CFPreferencesSetValue(CFSTR("autoDisableThreshold"), n, kBPSaverDomain, BPSaverUser(), kCFPreferencesAnyHost);
        CFRelease(n);
    }
    CFPreferencesSynchronize(kBPSaverDomain, BPSaverUser(), kCFPreferencesAnyHost);
    notify_post(kBPSaverPrefsNotification);
}

#pragma mark - Actions

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

static _CDBatterySaver *BPSaver(void) {
    static _CDBatterySaver *saver;
    if (!saver) {
        dlopen("/System/Library/PrivateFrameworks/CoreDuet.framework/CoreDuet", RTLD_LAZY);
        saver = [NSClassFromString(@"_CDBatterySaver") batterySaver];
    }
    return saver;
}

static BPState gState;
static BPAutoState gAuto;

static void BPSetLowPower(BOOL on, NSInteger capacity) {
    _CDBatterySaver *saver = BPSaver();
    if (!saver) { NSLog(@"batteryplusd: CoreDuet battery saver unavailable"); gAuto.session = gAuto.pending = NO; BPSaveSession(NO); return; }
    // Off uses the source iOS uses for its own 80% turn-off.
    NSString *const __unsafe_unretained *sysDisable = (NSString *const __unsafe_unretained *)dlsym(RTLD_DEFAULT, "kLPMSourceSystemDisable");
    NSString *source = on ? @"BatteryPlus" : (sysDisable && *sysDisable ? *sysDisable : @"SystemDisable");
    NSLog(@"batteryplusd: %ld%%, turning Low Power Mode %s", (long)capacity, on ? "on" : "off");
    [saver setPowerMode:on ? 1 : 0 fromSource:source withCompletion:^(BOOL ok, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) {
                NSLog(@"batteryplusd: setPowerMode failed: %@", error);
                if (on) { gAuto.session = gAuto.pending = NO; BPSaveSession(NO); }
                return;
            }
            if (!on) notify_post(kBPAutoDisabledNotification); // iOS's "Low Power Mode Turned Off" alert
        });
    }];
}

static void BPEvaluate(const char *why) {
    NSInteger cap; BOOL conn;
    if (!BPReadBattery(&cap, &conn)) return;
    if (BPStep(&gState, gEnabled, gLevel, cap, conn)) {
        NSLog(@"batteryplusd: %ld%% reached while connected (%s), showing reminder", (long)cap, why);
        BPShowAlert(gLevel);
    }
    BOOL wasSession = gAuto.session;
    BPAutoAction a = BPAutoStep(&gAuto, gAutoEnabled, gAutoLevel, cap, BPReadLowPower());
    if (gAuto.session != wasSession) BPSaveSession(gAuto.session);
    if (a == BPAutoTurnOn) BPSetLowPower(YES, cap);
    else if (a == BPAutoTurnOff) BPSetLowPower(NO, cap);
}

// Start state: no reminder or Low Power Mode change right away, so daemon restarts don't act.
// A session saved before a restart continues if Low Power Mode is still on.
static void BPResetState(BOOL keepSession) {
    NSInteger cap; BOOL conn;
    if (!BPReadBattery(&cap, &conn)) return;
    gState = (BPState){0};
    BPStep(&gState, NO, gLevel, cap, conn);
    gAuto = (BPAutoState){.armed = cap > gAutoLevel, .session = keepSession && BPReadLowPower()};
    BPSaveSession(gAuto.session);
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
        if (argc >= 2 && !strcmp(argv[1], "restore")) {
            BPSetSystemAutoOff(YES);
            return 0;
        }
        if (argc >= 2 && !strcmp(argv[1], "status")) {
            BPLoadPrefs();
            NSInteger cap = -1; BOOL conn = NO;
            BOOL ok = BPReadBattery(&cap, &conn);
            CFPreferencesSynchronize(kBPSaverDomain, BPSaverUser(), kCFPreferencesAnyHost);
            CFPropertyListRef th = CFPreferencesCopyValue(CFSTR("autoDisableThreshold"), kBPSaverDomain, BPSaverUser(), kCFPreferencesAnyHost);
            printf("enabled=%d level=%ld read=%d capacity=%ld connected=%d\n", gEnabled, (long)gLevel, ok, (long)cap, conn);
            printf("lpmAuto=%d lpmAutoLevel=%ld lowPower=%d lpmAutoActive=%d autoDisableThreshold=%s\n", gAutoEnabled, (long)gAutoLevel,
                   BPReadLowPower(), BPPrefBool(CFSTR("lpmAutoActive")), th ? [[(__bridge id)th description] UTF8String] : "(iOS default, 80)");
            if (th) CFRelease(th);
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
        if (argc >= 3 && !strcmp(argv[1], "simulate-lpm")) {
            // The first line sets the start state, like a daemon start.
            BPAutoState st = {0};
            NSInteger level = atoi(argv[2]);
            BOOL first = YES;
            char line[128];
            while (fgets(line, sizeof line, stdin)) {
                int cap, lpm;
                if (sscanf(line, "%d %d", &cap, &lpm) != 2) continue;
                if (first) { st.armed = cap > level; first = NO; }
                BPAutoAction a = BPAutoStep(&st, YES, level, cap, lpm != 0);
                printf("cap=%3d lowpower=%d -> %s\n", cap, lpm, a == BPAutoTurnOn ? "TURN ON" : a == BPAutoTurnOff ? "TURN OFF" : "-");
            }
            return 0;
        }

        BPLoadPrefs();
        BPResetState(BPPrefBool(CFSTR("lpmAutoActive")));
        BPSetSystemAutoOff(NO);

        dispatch_queue_t q = dispatch_get_main_queue();
        int token;
        notify_register_dispatch(kBPNotification, &token, q, ^(int t) {
            BOOL wasAuto = gAutoEnabled;
            NSInteger wasAutoLevel = gAutoLevel;
            BPLoadPrefs();
            // A changed reminder level starts from the current state, like a fresh start.
            NSInteger c; BOOL x;
            if (BPReadBattery(&c, &x)) { gState = (BPState){0}; BPStep(&gState, NO, gLevel, c, x); }
            // Turning Automatic on or choosing a level acts on the current level right away.
            if ((gAutoEnabled && !wasAuto) || (gAutoEnabled && wasAutoLevel != gAutoLevel)) {
                gAuto.armed = YES;
                BPEvaluate("settings");
            }
        });
        // Percentage changes and plug/unplug events (IOPowerSources notify names), and Low Power Mode.
        notify_register_dispatch("com.apple.system.powersources.percent", &token, q, ^(int t) { BPEvaluate("percent"); });
        notify_register_dispatch("com.apple.system.powersources.attach", &token, q, ^(int t) { BPEvaluate("attach"); });
        notify_register_dispatch("com.apple.system.powersources.source", &token, q, ^(int t) { BPEvaluate("source"); });
        notify_register_dispatch(kBPLowPowerNotification, &token, q, ^(int t) { BPEvaluate("lowpower"); });

        // launchd stops the daemon with SIGTERM (removal, upgrade): give iOS its 80% back first.
        signal(SIGTERM, SIG_IGN);
        dispatch_source_t term = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, q);
        dispatch_source_set_event_handler(term, ^{
            BPSetSystemAutoOff(YES);
            exit(0);
        });
        dispatch_resume(term);
        CFRunLoopRun();
    }
}
