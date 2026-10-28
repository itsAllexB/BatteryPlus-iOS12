// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// BatteryPlus 1.1.0
// Brings the Battery Health and Charging pages of modern iOS to Settings > Battery on iOS 12 iPads,
// and the Low Power Mode switch that iOS 12 only shows on iPhone.
//
// Hook point (Preferences.app, iOS 12):
//   /System/Library/PreferenceBundles/BatteryUsageUI.bundle, principal class BatteryUIController.
//   -[BatteryUIController specifiers] builds the page as: battery percentage + Low Power Mode,
//   the usage graphs, then the array returned by -setUpBatteryHealthSpecifiers (a group with the
//   native "Battery Health" link, which that method only returns on iPhone), then the spinner and
//   the per-app list. We return our own group (Battery Health, Charging) from that method, so the
//   rows sit where iOS puts Battery Health on iPhone and are rebuilt by every reload of the page.
//   The bundle is loaded lazily when Battery is opened, so the hooks are installed once it is
//   loaded (see BPImageAdded).
//
// Low Power Mode: the Battery page builds iPhone's "Low Power Mode" switch (with an iPad footer,
//   FOOTNOTE_BATTERYSAVERMODE_IPAD) only when +[PLModelingUtilities isLowPowerModeSupported] is YES,
//   which is a MobileGestalt device-class check. Everything behind the switch is not device specific:
//   it calls CoreDuet's _CDBatterySaver, contextstored sets com.apple.system.batterysavermode and the
//   system reacts as on iPhone (see the README for what was verified on an iPad mini 2). So inside
//   Settings only, that check answers YES and Apple's own switch, setter and footer are used.

#import <mach-o/dyld.h>
#import <dlfcn.h>
#import "BPControllers.h"
#import "BPBattery.h"

@interface BatteryUIController : PSListController
@end

@interface PLModelingUtilities : NSObject
@end

%group BatteryUI
%hook BatteryUIController

- (NSArray *)setUpBatteryHealthSpecifiers {
    NSArray *orig = %orig;
    NSMutableArray *a = [orig isKindOfClass:[NSArray class]] ? [orig mutableCopy] : [NSMutableArray array];

    PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
    group.identifier = @"BATTERYPLUS_GROUP";
    [a addObject:group];

    PSSpecifier *health = [PSSpecifier preferenceSpecifierNamed:@"Battery Health" target:self set:NULL get:@selector(bp_healthValue:) detail:[BPHealthController class] cell:PSLinkListCell edit:Nil];
    health.identifier = @"BATTERYPLUS_HEALTH";
    [a addObject:health];

    PSSpecifier *charging = [PSSpecifier preferenceSpecifierNamed:@"Charging" target:self set:NULL get:NULL detail:[BPChargingController class] cell:PSLinkCell edit:Nil];
    charging.identifier = @"BATTERYPLUS_CHARGING";
    [a addObject:charging];

    PSSpecifier *bar = [PSSpecifier preferenceSpecifierNamed:@"Status Bar" target:self set:NULL get:NULL detail:[BPStatusBarController class] cell:PSLinkCell edit:Nil];
    bar.identifier = @"BATTERYPLUS_STATUSBAR";
    [a addObject:bar];
    return a;
}

%new
- (id)bp_healthValue:(PSSpecifier *)specifier {
    return [BPBatteryInfo currentInfo].healthText;
}

%end
%end

%group LowPowerSwitch
%hook PLModelingUtilities
+ (BOOL)isLowPowerModeSupported {
    return YES;
}
%end
%end

static BOOL gBPHooked, gBPImageSeen;

static void BPTryInit(void) {
    if (gBPHooked || !gBPImageSeen) return;
    Class c = objc_getClass("BatteryUIController");
    if (!c || ![c instancesRespondToSelector:@selector(setUpBatteryHealthSpecifiers)]) return;
    gBPHooked = YES;
    Class pl = objc_getClass("PLModelingUtilities");
    if (!pl) {
        dlopen("/System/Library/PrivateFrameworks/PowerLog.framework/PowerLog", RTLD_LAZY);
        pl = objc_getClass("PLModelingUtilities");
    }
    if (pl && class_getClassMethod(pl, @selector(isLowPowerModeSupported))) %init(LowPowerSwitch, PLModelingUtilities = pl);
    %init(BatteryUI, BatteryUIController = c);
}

// dyld reports the image before the Objective-C runtime has registered its classes, so the hooks
// are installed on the first chance after that: NSBundle's did-load notification (Settings loads
// the bundle with -[NSBundle load]), the next image, or the next main-queue turn.
static void BPImageAdded(const struct mach_header *mh, intptr_t slide) {
    if (gBPHooked) return;
    if (!gBPImageSeen) {
        Dl_info info;
        if (!dladdr(mh, &info) || !info.dli_fname || !strstr(info.dli_fname, "/BatteryUsageUI.bundle/BatteryUsageUI")) return;
        gBPImageSeen = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ BPTryInit(); });
        return;
    }
    BPTryInit();
}

%ctor {
    [[NSNotificationCenter defaultCenter] addObserverForName:NSBundleDidLoadNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        BPTryInit();
    }];
    _dyld_register_func_for_add_image(BPImageAdded);
}
