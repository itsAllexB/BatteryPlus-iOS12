// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

#import "BPControllers.h"
#import "BPBattery.h"
#import "BPStatusBarPrefs.h"
#import <dlfcn.h>

static PSSpecifier *BPGroup(NSString *ident, NSString *name, NSString *footer) {
    PSSpecifier *g = name ? [PSSpecifier groupSpecifierWithName:name] : [PSSpecifier emptyGroupSpecifier];
    g.identifier = ident;
    if (footer) [g setProperty:footer forKey:@"footerText"];
    return g;
}

static PSSpecifier *BPValueRow(id target, NSString *ident, NSString *name, NSString *value) {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name target:target set:NULL get:@selector(bp_value:) detail:Nil cell:PSTitleValueCell edit:Nil];
    s.identifier = ident;
    [s setProperty:value forKey:@"bpValue"];
    return s;
}

// Write through cfprefsd before telling the daemon and the status bars, so they read the new value.
BOOL BPWritePref(id value, PSSpecifier *specifier) {
    NSString *domain = [specifier propertyForKey:@"defaults"], *key = [specifier propertyForKey:@"key"];
    if (!domain.length || !key.length) return NO;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)domain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    BPStatusBarPrefsPublish();
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)kBPNotification, NULL, NULL, YES);
    return YES;
}

id BPReadPref(PSSpecifier *specifier) {
    NSString *domain = [specifier propertyForKey:@"defaults"], *key = [specifier propertyForKey:@"key"];
    if (!domain.length || !key.length) return nil;
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    id v = (__bridge_transfer id)CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)domain);
    return v ?: [specifier propertyForKey:@"default"];
}

void BPSetPref(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)kBPDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kBPDomain);
    BPStatusBarPrefsPublish();
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)kBPNotification, NULL, NULL, YES);
}

BOOL BPPrefIsOn(NSString *key) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kBPDomain);
    id v = (__bridge_transfer id)CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kBPDomain);
    return [v respondsToSelector:@selector(boolValue)] && [v boolValue];
}

static NSInteger BPAutoLevel(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kBPDomain);
    id v = (__bridge_transfer id)CFPreferencesCopyAppValue(CFSTR("lpmAutoLevel"), (__bridge CFStringRef)kBPDomain);
    NSInteger l = [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : 20;
    return (l >= 5 && l <= 20) ? l : 20;
}

@interface _CDBatterySaver : NSObject
+ (instancetype)batterySaver;
- (void)setPowerMode:(long long)mode fromSource:(NSString *)source withCompletion:(void (^)(BOOL ok, NSError *error))completion;
@end

BOOL BPLowPowerOn(void) {
    return [NSProcessInfo processInfo].lowPowerModeEnabled;
}

void BPSetLowPower(BOOL on, void (^done)(void)) {
    if (!NSClassFromString(@"_CDBatterySaver")) dlopen("/System/Library/PrivateFrameworks/CoreDuet.framework/CoreDuet", RTLD_LAZY);
    _CDBatterySaver *saver = [NSClassFromString(@"_CDBatterySaver") batterySaver];
    NSString *const __unsafe_unretained *src = (NSString *const __unsafe_unretained *)dlsym(RTLD_DEFAULT, "kLPMSourceSettings");
    if (!saver) { if (done) done(); return; }
    [saver setPowerMode:on ? 1 : 0 fromSource:(src && *src) ? *src : @"Settings" withCompletion:^(BOOL ok, NSError *error) {
        if (done) dispatch_async(dispatch_get_main_queue(), done);
    }];
}

static PSSpecifier *BPSwitch(id target, NSString *ident, NSString *name, NSString *key, BOOL def) {
    PSSpecifier *sw = [PSSpecifier preferenceSpecifierNamed:name target:target set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:Nil cell:PSSwitchCell edit:Nil];
    sw.identifier = ident;
    [sw setProperty:kBPDomain forKey:@"defaults"];
    [sw setProperty:key forKey:@"key"];
    [sw setProperty:@(def) forKey:@"default"];
    return sw;
}

#pragma mark - Battery Health

@implementation BPHealthController

- (NSString *)title { return @"Battery Health"; }

- (NSArray *)specifiers {
    if (!_specifiers) {
        BPBatteryInfo *info = [BPBatteryInfo currentInfo];
        NSMutableArray *a = [NSMutableArray array];
        if (info.healthKnown) {
            NSString *footer = info.healthNormal
                ? @"This iPad battery is performing as expected."
                : @"This iPad battery has significantly reduced capacity, so iPad may run for less time between charges. An Apple Authorized Service Provider can replace the battery.";
            [a addObject:BPGroup(@"BP_HEALTH_GROUP", nil, footer)];
            [a addObject:BPValueRow(self, @"BP_HEALTH", @"Battery Health", info.healthText)];
            [a addObject:BPGroup(@"BP_CAPACITY_GROUP", nil, @"This is a measure of battery capacity relative to when it was new. Lower capacity may result in fewer hours of use between charges.")];
            [a addObject:BPValueRow(self, @"BP_CAPACITY", @"Maximum Capacity", [NSString stringWithFormat:@"%ld%%", (long)info.maximumCapacity])];
        }
        NSMutableArray *details = [NSMutableArray array];
        if (info.cycleCount >= 0)
            [details addObject:BPValueRow(self, @"BP_CYCLES", @"Cycle Count", [NSNumberFormatter localizedStringFromNumber:@(info.cycleCount) numberStyle:NSNumberFormatterDecimalStyle])];
        if (info.manufactureDateText)
            [details addObject:BPValueRow(self, @"BP_MFG", @"Manufacture Date", info.manufactureDateText)];
        if (info.firstUseDateText)
            [details addObject:BPValueRow(self, @"BP_FIRSTUSE", @"First Use", info.firstUseDateText)];
        if (details.count) {
            [a addObject:BPGroup(@"BP_DETAILS_GROUP", nil, nil)];
            [a addObjectsFromArray:details];
        }
        if (!a.count) [a addObject:BPGroup(@"BP_NONE", nil, @"This iPad doesn't report battery health information.")];
        _specifiers = a;
    }
    return _specifiers;
}

- (id)bp_value:(PSSpecifier *)specifier { return [specifier propertyForKey:@"bpValue"]; }

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers]; // values can change while Settings stays open
}

@end

#pragma mark - Charging

@implementation BPChargingController

- (NSString *)title { return @"Charging"; }

- (NSString *)reminderFooter {
    NSNumber *level = (__bridge_transfer NSNumber *)CFPreferencesCopyAppValue(CFSTR("reminderLevel"), (__bridge CFStringRef)kBPDomain);
    NSInteger pct = [level isKindOfClass:[NSNumber class]] ? level.integerValue : 80;
    return [NSString stringWithFormat:@"When iPad charges to %ld%%, an alert reminds you to unplug it. iPad keeps charging until you do: this is a reminder, not a limit.", (long)pct];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *a = [NSMutableArray array];
        [a addObject:BPGroup(@"BP_INTRO", nil, @"Keeping iPad at full charge for long periods wears the battery faster. Unplugging it when it's around 80% helps preserve battery lifespan over time.")];

        [a addObject:BPGroup(@"BP_REMINDER_GROUP", nil, [self reminderFooter])];
        PSSpecifier *sw = [PSSpecifier preferenceSpecifierNamed:@"Unplug Reminder" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:Nil cell:PSSwitchCell edit:Nil];
        sw.identifier = @"BP_REMINDER";
        [sw setProperty:kBPDomain forKey:@"defaults"];
        [sw setProperty:@"reminderEnabled" forKey:@"key"];
        [sw setProperty:@NO forKey:@"default"];
        [sw setProperty:kBPNotification forKey:@"PostNotification"];
        [a addObject:sw];

        PSSpecifier *lvl = [PSSpecifier preferenceSpecifierNamed:@"Remind At" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:NSClassFromString(@"PSListItemsController") cell:PSLinkListCell edit:Nil];
        lvl.identifier = @"BP_REMINDER_LEVEL";
        [lvl setProperty:kBPDomain forKey:@"defaults"];
        [lvl setProperty:@"reminderLevel" forKey:@"key"];
        [lvl setProperty:@80 forKey:@"default"];
        [lvl setProperty:kBPNotification forKey:@"PostNotification"];
        [lvl setValues:@[@80, @85, @90, @95, @100] titles:@[@"80%", @"85%", @"90%", @"95%", @"100%"]];
        [a addObject:lvl];
        _specifiers = a;
    }
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    if (!BPWritePref(value, specifier)) [super setPreferenceValue:value specifier:specifier];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    return BPReadPref(specifier) ?: [super readPreferenceValue:specifier];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers]; // the reminder footer names the chosen level
}

@end

#pragma mark - Low Power Mode

// Settings > Battery > Low Power Mode. Automatic (batteryplusd turns it on at the chosen level and
// off at 80%) above Manual (the switch itself). What Automatic turned on is turned off again at 80%;
// what you turn on yourself stays on until you turn it off (see daemon/main.m).
@implementation BPLowPowerController

- (NSString *)title { return @"Low Power Mode"; }

- (instancetype)init {
    if ((self = [super init]))
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(bp_powerStateChanged:) name:NSProcessInfoPowerStateDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)bp_powerStateChanged:(NSNotification *)n {
    dispatch_async(dispatch_get_main_queue(), ^{ [self reloadSpecifiers]; });
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        BOOL autoOn = BPPrefIsOn(@"lpmAuto");
        NSInteger level = BPAutoLevel();
        NSMutableArray *a = [NSMutableArray array];

        NSString *autoFooter = autoOn
            ? [NSString stringWithFormat:@"Low Power Mode turns on when the battery drops to %ld%%, and off again when iPad charges to 80%%.", (long)level]
            : @"Turns Low Power Mode on when the battery is low, and off again when iPad charges to 80%.";
        [a addObject:BPGroup(@"BP_LPM_AUTO_GROUP", @"Automatic", autoFooter)];
        [a addObject:BPSwitch(self, @"BP_LPM_AUTO", @"Turn On Automatically", @"lpmAuto", NO)];
        if (autoOn) {
            PSSpecifier *lvl = [PSSpecifier preferenceSpecifierNamed:@"Turn On At" target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:NSClassFromString(@"PSListItemsController") cell:PSLinkListCell edit:Nil];
            lvl.identifier = @"BP_LPM_AUTO_LEVEL";
            [lvl setProperty:kBPDomain forKey:@"defaults"];
            [lvl setProperty:@"lpmAutoLevel" forKey:@"key"];
            [lvl setProperty:@20 forKey:@"default"];
            [lvl setValues:@[@5, @10, @15, @20] titles:@[@"5%", @"10%", @"15%", @"20%"]];
            [a addObject:lvl];
        }

        NSString *manualFooter;
        if (BPLowPowerOn() && BPPrefIsOn(@"lpmAutoActive"))
            manualFooter = [NSString stringWithFormat:@"Low Power Mode was turned on automatically and turns off when iPad charges to 80%%. If you turn it off, it stays off until the battery drops to %ld%% again.", (long)level];
        else
            manualFooter = @"Low Power Mode temporarily reduces background activity like downloads and mail fetch until you can fully charge your iPad. When you turn it on yourself, here or in Control Center, it stays on until you turn it off.";
        [a addObject:BPGroup(@"BP_LPM_MANUAL_GROUP", @"Manual", manualFooter)];
        PSSpecifier *sw = [PSSpecifier preferenceSpecifierNamed:@"Low Power Mode" target:self set:@selector(bp_setLowPower:specifier:) get:@selector(bp_lowPower:) detail:Nil cell:PSSwitchCell edit:Nil];
        sw.identifier = @"BP_LPM_MANUAL";
        [a addObject:sw];
        _specifiers = a;
    }
    return _specifiers;
}

- (id)bp_lowPower:(PSSpecifier *)specifier {
    return @(BPLowPowerOn());
}

- (void)bp_setLowPower:(id)value specifier:(PSSpecifier *)specifier {
    BPSetLowPower([value boolValue], ^{ [self reloadSpecifiers]; });
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    if (!BPWritePref(value, specifier)) [super setPreferenceValue:value specifier:specifier];
    if ([[specifier propertyForKey:@"key"] isEqualToString:@"lpmAuto"]) [self reloadSpecifiers]; // shows or hides Turn On At
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    return BPReadPref(specifier) ?: [super readPreferenceValue:specifier];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers]; // the footers name the chosen level and the current state
}

@end
