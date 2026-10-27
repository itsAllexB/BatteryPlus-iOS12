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

// Settings > Battery > Battery Health
@interface BPHealthController : PSListController
@end

// Settings > Battery > Charging
@interface BPChargingController : PSListController
@end

// Settings > Battery > Status Bar
@interface BPStatusBarController : PSListController
@end

// The (disabled) Charge Limit slider with 80 / 85 / 90 / 95 / 100 % marks.
@interface BPChargeLimitCell : PSTableCell
@end
