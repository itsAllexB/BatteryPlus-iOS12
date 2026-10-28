// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

#import "BPControllers.h"
#import "BPBattery.h"
#import "BPStatusBarPrefs.h"
#import <sys/utsname.h>

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
static BOOL BPWritePref(id value, PSSpecifier *specifier) {
    NSString *domain = [specifier propertyForKey:@"defaults"], *key = [specifier propertyForKey:@"key"];
    if (!domain.length || !key.length) return NO;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)domain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    BPStatusBarPrefsPublish();
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)kBPNotification, NULL, NULL, YES);
    return YES;
}

static id BPReadPref(PSSpecifier *specifier) {
    NSString *domain = [specifier propertyForKey:@"defaults"], *key = [specifier propertyForKey:@"key"];
    if (!domain.length || !key.length) return nil;
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    id v = (__bridge_transfer id)CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)domain);
    return v ?: [specifier propertyForKey:@"default"];
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

#pragma mark - Charge Limit cell

static const NSInteger kBPLimitSteps[] = {80, 85, 90, 95, 100};

@implementation BPChargeLimitCell {
    UISlider *_slider;
    NSArray<UILabel *> *_marks;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid specifier:(PSSpecifier *)specifier {
    if ((self = [super initWithStyle:style reuseIdentifier:rid specifier:specifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.textLabel.text = nil;
        _slider = [UISlider new];
        _slider.minimumValue = 80;
        _slider.maximumValue = 100;
        _slider.value = 100;
        _slider.enabled = NO;
        [self.contentView addSubview:_slider];
        NSMutableArray *marks = [NSMutableArray array];
        for (NSUInteger i = 0; i < 5; i++) {
            UILabel *l = [UILabel new];
            l.text = [NSString stringWithFormat:@"%ld%%", (long)kBPLimitSteps[i]];
            l.font = [UIFont systemFontOfSize:13];
            l.textColor = [UIColor colorWithWhite:0.56 alpha:1];
            l.textAlignment = NSTextAlignmentCenter;
            [l sizeToFit];
            [self.contentView addSubview:l];
            [marks addObject:l];
        }
        _marks = marks;
    }
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    self.textLabel.text = nil;
    self.detailTextLabel.text = nil;
    NSNumber *v = [specifier propertyForKey:@"value"];
    _slider.value = v ? v.floatValue : 100;
    BOOL enabled = [[specifier propertyForKey:@"enabled"] boolValue];
    _slider.enabled = enabled;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    CGFloat inset = MAX(self.separatorInset.left, 15);
    _slider.frame = CGRectMake(inset, 10, b.size.width - 2 * inset, 30);
    CGRect track = [_slider trackRectForBounds:_slider.bounds];
    for (NSUInteger i = 0; i < _marks.count; i++) {
        CGRect thumb = [_slider thumbRectForBounds:_slider.bounds trackRect:track value:kBPLimitSteps[i]];
        UILabel *l = _marks[i];
        CGPoint c = [self.contentView convertPoint:CGPointMake(CGRectGetMidX(thumb), 0) fromView:_slider];
        l.center = CGPointMake(c.x, 52);
    }
}

@end

#pragma mark - Charging

@implementation BPChargingController

- (NSString *)title { return @"Charging"; }

// iPad4,x are the A7 iPads (iPad Air, iPad mini 2 and 3), the hardware this was verified on.
- (NSString *)chargeLimitFooter {
    struct utsname u;
    BOOL a7 = uname(&u) == 0 && strncmp(u.machine, "iPad4,", 6) == 0;
    if (a7) return @"Not available on this iPad. A7 iPads like this one can't pause charging while power is connected: the power controller ignores the request that newer models use for this, so iPad always charges to 100%. BatteryPlus leaves charging alone rather than use an unsafe workaround.";
    return @"Not available on this iPad. BatteryPlus has no verified, safe way to pause charging on it, so iPad charges to 100% as usual.";
}

- (NSString *)reminderFooter {
    NSNumber *level = (__bridge_transfer NSNumber *)CFPreferencesCopyAppValue(CFSTR("reminderLevel"), (__bridge CFStringRef)kBPDomain);
    NSInteger pct = [level isKindOfClass:[NSNumber class]] ? level.integerValue : 80;
    return [NSString stringWithFormat:@"When iPad charges to %ld%%, an alert reminds you to unplug it. iPad keeps charging until you do: this is a reminder, not a limit.", (long)pct];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *a = [NSMutableArray array];
        [a addObject:BPGroup(@"BP_INTRO", nil, @"Keeping iPad at full charge for long periods wears the battery faster. Unplugging it when it's around 80% helps preserve battery lifespan over time.")];

        [a addObject:BPGroup(@"BP_LIMIT_GROUP", @"Charge Limit", [self chargeLimitFooter])];
        PSSpecifier *limit = [PSSpecifier preferenceSpecifierNamed:@"Charge Limit" target:self set:NULL get:NULL detail:Nil cell:PSStaticTextCell edit:Nil];
        limit.identifier = @"BP_LIMIT";
        [limit setProperty:[BPChargeLimitCell class] forKey:@"cellClass"];
        [limit setProperty:@68 forKey:@"height"];
        [limit setProperty:@100 forKey:@"value"];
        [limit setProperty:@NO forKey:@"enabled"];
        [a addObject:limit];

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

#pragma mark - Status Bar

@implementation BPStatusBarController

- (NSString *)title { return @"Status Bar"; }

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *a = [NSMutableArray array];
        [a addObject:BPGroup(@"BP_SB_COLORS_GROUP", nil, @"Like modern iOS, the battery icon turns yellow in Low Power Mode (also while charging), green while iPad is charging, and red at 20% or less. Turn this off for the iOS 12 colours.")];
        [a addObject:BPSwitch(self, @"BP_SB_COLORS", @"Battery Colours", @"sbColors", YES)];
        [a addObject:BPGroup(@"BP_SB_PERCENT_GROUP", nil, @"Shows the battery percentage inside the battery icon, like modern iOS, whether or not Battery Percentage is on. Turn this off to keep the iOS 12 percentage next to the icon.")];
        [a addObject:BPSwitch(self, @"BP_SB_PERCENT", @"Percentage Inside Icon", @"sbPercentInside", NO)];
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

@end
