// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>

#define kBPDomain @"com.itsallexb.batteryplus"
#define kBPNotification @"com.itsallexb.batteryplus/prefschanged"

@interface PSSpecifier (BPPrivate)
- (void)setValues:(NSArray *)values titles:(NSArray *)titles;
@end

// BatteryPlus preferences (the specifier's "defaults" and "key"), written through cfprefsd, then
// announced to batteryplusd and the status bars.
BOOL BPWritePref(id value, PSSpecifier *specifier);
id BPReadPref(PSSpecifier *specifier);
// The same for one BatteryPlus key.
void BPSetPref(NSString *key, id value);
BOOL BPPrefIsOn(NSString *key);

// Low Power Mode as apps see it, and the switch Settings and Control Center use (CoreDuet's battery saver).
BOOL BPLowPowerOn(void);
void BPSetLowPower(BOOL on, void (^done)(void));

// Settings > Battery > Battery Health
@interface BPHealthController : PSListController
@end

// Settings > Battery > Charging
@interface BPChargingController : PSListController
@end

// Settings > Battery > Low Power Mode
@interface BPLowPowerController : PSListController
@end
