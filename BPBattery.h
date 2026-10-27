// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

#import <Foundation/Foundation.h>

// Battery information read from the gas gauge through IOKit (IOPMPowerSource, which on the
// A7 iPads is AppleARMPMUCharger). Every value is optional: when the hardware does not expose
// it, the property is -1 / nil and the UI hides the row instead of showing a guess.
@interface BPBatteryInfo : NSObject
@property (nonatomic, readonly) NSInteger designCapacity;      // mAh, -1 if unknown
@property (nonatomic, readonly) NSInteger fullChargeCapacity;  // mAh, -1 if unknown
@property (nonatomic, readonly) NSInteger maximumCapacity;     // percent, -1 if unknown
@property (nonatomic, readonly) NSInteger cycleCount;          // -1 if unknown
@property (nonatomic, readonly) NSDate *manufactureDate;       // nil if unknown
@property (nonatomic, readonly) NSDate *firstUseDate;          // nil if unknown
@property (nonatomic, readonly) BOOL healthKnown;
@property (nonatomic, readonly) BOOL healthNormal;             // maximumCapacity >= 80

+ (instancetype)currentInfo;
// Exposed for testing: decodes "D350"-style ManufactureDate / serial fields.
+ (NSDate *)manufactureDateFromCode:(NSString *)code operatingHours:(NSInteger)hours now:(NSDate *)now;
- (NSString *)healthText;           // "Normal" / "Service", nil if unknown
- (NSString *)manufactureDateText;  // "December 2013"
- (NSString *)firstUseDateText;
@end
