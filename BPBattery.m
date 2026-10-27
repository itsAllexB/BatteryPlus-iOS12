// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

#import "BPBattery.h"
#include <IOKit/IOKitLib.h>

// How the values are computed
//
// Maximum Capacity = round(100 * full-charge capacity / design capacity), at most 100 %.
//   Full-charge capacity is the gauge's current FCC: NominalChargeCapacity where the driver has it
//   (AppleSmartBattery, iPhone 8 and later), otherwise AppleRawMaxCapacity (AppleARMPMUCharger,
//   the A7/A8 generation), otherwise BatteryData.MaxCapacity. This is the ratio iOS shows as
//   "Maximum Capacity" on iPhone; on iOS 12 powerlogd computes it there, but not on iPad.
// Battery Health = "Normal" at 80 % and above, "Service" below (Apple's threshold).
// Cycle Count = CycleCount (or BatteryData.CycleCount).
// Manufacture Date = decoded from BatteryData.ManufactureDate ("D350") or from the pack serial:
//   for these 17-character serials the 4th character is the last digit of the year and the 5th and
//   6th are the week (Apple's ManufactureDate property is exactly characters 3-6 of the serial).
//   The decade is not stored. It is chosen as the only decade that puts the date in the past and
//   before (now - the gauge's TotalOperatingTime); if that leaves more than one decade, the row is
//   hidden.
// First Use = only newer gauges store it (iPhone 15 and later); this generation has no such field,
//   so the row stays hidden.

static id BPValue(NSDictionary *props, NSString *key) {
    id v = props[key];
    if (!v) v = [props[@"BatteryData"] isKindOfClass:[NSDictionary class]] ? props[@"BatteryData"][key] : nil;
    return v;
}

static NSInteger BPInt(NSDictionary *props, NSString *key) {
    id v = BPValue(props, key);
    return [v isKindOfClass:[NSNumber class]] ? [v integerValue] : -1;
}

static NSDictionary *BPCopyPowerSourceProperties(void) {
    NSDictionary *result = nil;
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!service) service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPMPowerSource"));
    if (service) {
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props)
            result = (__bridge_transfer NSDictionary *)props;
        IOObjectRelease(service);
    }
    return result;
}

@implementation BPBatteryInfo

+ (NSDate *)manufactureDateFromCode:(NSString *)code operatingHours:(NSInteger)hours now:(NSDate *)now {
    // code = "YWW": last digit of the year, then the week (01-53).
    if (code.length != 3) return nil;
    for (NSUInteger i = 0; i < 3; i++) if (!isdigit([code characterAtIndex:i])) return nil;
    NSInteger digit = [[code substringToIndex:1] integerValue];
    NSInteger week = [[code substringFromIndex:1] integerValue];
    if (week < 1 || week > 53) return nil;

    NSCalendar *iso = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierISO8601];
    iso.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
    NSInteger thisYear = [iso component:NSCalendarUnitYear fromDate:now];
    NSDate *latest = hours > 0 ? [now dateByAddingTimeInterval:-(NSTimeInterval)hours * 3600.0] : now;

    NSDate *found = nil;
    NSUInteger matches = 0;
    // Apple's lithium-ion packs with this serial format exist from about 2008 on.
    for (NSInteger year = 2000 + digit; year <= thisYear; year += 10) {
        if (year < 2008) continue;
        NSDateComponents *c = [NSDateComponents new];
        c.yearForWeekOfYear = year;
        c.weekOfYear = week;
        c.weekday = 5; // Thursday: the ISO week belongs to the month of its Thursday
        NSDate *d = [iso dateFromComponents:c];
        if (!d || [iso component:NSCalendarUnitYearForWeekOfYear fromDate:d] != year) continue;
        if ([d compare:latest] == NSOrderedDescending) continue;
        found = d;
        matches++;
    }
    return matches == 1 ? found : nil;
}

+ (instancetype)currentInfo {
    return [[self alloc] initWithProperties:BPCopyPowerSourceProperties()];
}

- (instancetype)initWithProperties:(NSDictionary *)props {
    if ((self = [super init])) {
        _designCapacity = BPInt(props, @"DesignCapacity");
        NSInteger fcc = BPInt(props, @"NominalChargeCapacity");
        if (fcc <= 0) fcc = BPInt(props, @"AppleRawMaxCapacity");
        if (fcc <= 0) fcc = BPInt(props, @"MaxCapacity") > 100 ? BPInt(props, @"MaxCapacity") : -1; // top-level MaxCapacity is a percentage on some models
        if (fcc <= 0 && [props[@"BatteryData"] isKindOfClass:[NSDictionary class]]) {
            id v = props[@"BatteryData"][@"MaxCapacity"];
            if ([v isKindOfClass:[NSNumber class]]) fcc = [v integerValue];
        }
        _fullChargeCapacity = fcc > 0 ? fcc : -1;
        _maximumCapacity = -1;
        if (_designCapacity >= 500 && _designCapacity <= 50000 && _fullChargeCapacity > 0) {
            long pct = lround(100.0 * (double)_fullChargeCapacity / (double)_designCapacity);
            _maximumCapacity = MIN(pct, 100);
        }
        _healthKnown = _maximumCapacity > 0;
        _healthNormal = _maximumCapacity >= 80;

        NSInteger cycles = BPInt(props, @"CycleCount");
        _cycleCount = cycles >= 0 ? cycles : -1;

        NSInteger hours = -1;
        id life = BPValue(props, @"LifetimeData");
        if ([life isKindOfClass:[NSDictionary class]] && [life[@"TotalOperatingTime"] isKindOfClass:[NSNumber class]])
            hours = [life[@"TotalOperatingTime"] integerValue];
        NSString *code = nil;
        id md = BPValue(props, @"ManufactureDate");
        if ([md isKindOfClass:[NSString class]] && [md length] == 4) code = [md substringFromIndex:1];
        if (!code) {
            id serial = props[@"Serial"] ?: BPValue(props, @"BatterySerialNumber");
            if ([serial isKindOfClass:[NSString class]] && [serial length] >= 17) code = [serial substringWithRange:NSMakeRange(3, 3)];
        }
        if (code) _manufactureDate = [BPBatteryInfo manufactureDateFromCode:code operatingHours:hours now:[NSDate date]];

        id first = BPValue(props, @"FirstUsageDate");
        if ([first isKindOfClass:[NSDate class]]) _firstUseDate = first;
    }
    return self;
}

- (NSString *)healthText {
    if (!_healthKnown) return nil;
    return _healthNormal ? @"Normal" : @"Service";
}

static NSString *BPMonthYear(NSDate *date) {
    if (!date) return nil;
    NSDateFormatter *f = [NSDateFormatter new];
    f.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
    [f setLocalizedDateFormatFromTemplate:@"MMMMyyyy"];
    return [f stringFromDate:date];
}

- (NSString *)manufactureDateText { return BPMonthYear(_manufactureDate); }
- (NSString *)firstUseDateText { return BPMonthYear(_firstUseDate); }

@end
