// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// BatteryPlus 1.2.0
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
//   Settings only, that check answers YES.
//
// The first group of the page then holds Apple's Battery Percentage and Low Power Mode switches
//   (found by their getters, getBatteryPercentageMode: and getBatterySaverMode:). BatteryPlus
//   replaces both with rows that open a page:
//   - Battery Percentage: Off, Next to Icon or Inside Icon. Apple's switch specifier is kept on the
//     row and its own setter writes Battery Percentage, so iOS sees the usual setting; Inside Icon
//     also sets BatteryPlus's sbPercentInside (see StatusBar.x). Battery Percentage stays on for
//     Inside Icon, so without BatteryPlus the percentage is still shown, next to the icon.
//     (Apple's getter also disabled the switch and reported it on in Low Power Mode, because iOS 12
//     then always shows the percentage; with BatteryPlus it follows the setting.)
//   - Low Power Mode: Automatic and Manual (BPLowPowerController, BPControllers.m). The group's
//     footer, about Low Power Mode, moves to that page.

#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BPControllers.h"
#import "BPBattery.h"

@interface BatteryUIController : PSListController
@end

@interface PLModelingUtilities : NSObject
@end

@interface PSSpecifier (BPTweak)
- (void)setValues:(NSArray *)values titles:(NSArray *)titles shortTitles:(NSArray *)shortTitles;
- (void)removePropertyForKey:(NSString *)key;
@property (nonatomic) NSInteger cellType;
@end

static SEL BPSpecifierSelector(PSSpecifier *s, const char *ivarName) {
    Ivar iv = class_getInstanceVariable([PSSpecifier class], ivarName);
    return iv ? *(SEL *)((uint8_t *)(__bridge void *)s + ivar_getOffset(iv)) : NULL;
}

// Replaces Apple's two switches (see the top of this file). It reads _specifiers directly
// (-specifierForID: calls -specifiers, which would come back here).
static void BPReplaceTopRows(PSListController *ctl) {
    Ivar specsIvar = class_getInstanceVariable([PSListController class], "_specifiers");
    if (!specsIvar) return;
    NSMutableArray *specs = object_getIvar(ctl, specsIvar);
    if (![specs isKindOfClass:[NSMutableArray class]]) return;
    NSUInteger pctIdx = NSNotFound, lpmIdx = NSNotFound;
    for (NSUInteger i = 0; i < specs.count; i++) {
        PSSpecifier *s = specs[i];
        if (![s isKindOfClass:[PSSpecifier class]]) continue;
        if ([s.identifier hasPrefix:@"BP_TOP_"]) return; // already replaced
        SEL getter = BPSpecifierSelector(s, "getter");
        if (getter == @selector(getBatteryPercentageMode:) && pctIdx == NSNotFound) pctIdx = i;
        if (getter == @selector(getBatterySaverMode:) && lpmIdx == NSNotFound) lpmIdx = i;
    }

    if (pctIdx != NSNotFound) {
        PSSpecifier *pct = [PSSpecifier preferenceSpecifierNamed:@"Battery Percentage" target:ctl set:@selector(bp_setPercentMode:specifier:) get:@selector(bp_percentMode:) detail:NSClassFromString(@"PSListItemsController") cell:PSLinkListCell edit:Nil];
        pct.identifier = @"BP_TOP_PERCENT";
        [pct setProperty:specs[pctIdx] forKey:@"bpSwitch"];
        [pct setValues:@[@0, @1, @2] titles:@[@"Off", @"Next to Icon", @"Inside Icon"] shortTitles:@[@"Off", @"Next to Icon", @"Inside Icon"]];
        [pct setProperty:@"Inside Icon shows the number inside the battery icon, like modern iOS." forKey:@"staticTextMessage"];
        specs[pctIdx] = pct;
    }
    if (lpmIdx != NSNotFound) {
        PSSpecifier *lpm = [PSSpecifier preferenceSpecifierNamed:@"Low Power Mode" target:ctl set:NULL get:@selector(bp_lowPowerValue:) detail:[BPLowPowerController class] cell:PSLinkListCell edit:Nil];
        lpm.identifier = @"BP_TOP_LPM";
        specs[lpmIdx] = lpm;
        for (NSInteger i = (NSInteger)lpmIdx - 1; i >= 0; i--) {
            PSSpecifier *g = specs[i];
            if ([g isKindOfClass:[PSSpecifier class]] && g.cellType == PSGroupCell) { [g removePropertyForKey:@"footerText"]; break; }
        }
    }
}

%group BatteryUI
%hook BatteryUIController

- (NSArray *)specifiers {
    NSArray *specs = %orig;
    BPReplaceTopRows(self);
    return specs;
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [self reloadSpecifierID:@"BP_TOP_PERCENT"];
    [self reloadSpecifierID:@"BP_TOP_LPM"];
}

- (void)_lowPowerModeChangedNotification:(id)note {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ [self reloadSpecifierID:@"BP_TOP_LPM"]; });
}

// 0 Off, 1 Next to Icon, 2 Inside Icon.
%new
- (id)bp_percentMode:(PSSpecifier *)specifier {
    if (BPPrefIsOn(@"sbPercentInside")) return @2;
    PSSpecifier *sw = [specifier propertyForKey:@"bpSwitch"];
    return @(sw && [[self readPreferenceValue:sw] boolValue] ? 1 : 0);
}

%new
- (void)bp_setPercentMode:(id)value specifier:(PSSpecifier *)specifier {
    NSInteger mode = [value integerValue];
    BPSetPref(@"sbPercentInside", @(mode == 2));
    PSSpecifier *sw = [specifier propertyForKey:@"bpSwitch"];
    SEL setter = sw ? BPSpecifierSelector(sw, "setter") : NULL;
    if (setter && [self respondsToSelector:setter])
        ((void (*)(id, SEL, id, id))objc_msgSend)(self, setter, @(mode != 0), sw);
}

%new
- (id)bp_lowPowerValue:(PSSpecifier *)specifier {
    if (BPLowPowerOn()) return @"On";
    return BPPrefIsOn(@"lpmAuto") ? @"Automatic" : @"Off";
}

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
