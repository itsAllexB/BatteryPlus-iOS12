// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// Control Center toggle for Low Power Mode on iOS 12 iPads (loaded by CCSupport).
//
// It is the iPhone module's logic on iPad: the state comes from NSProcessInfo, a tap asks CoreDuet's
// battery saver (contextstored) to change the mode with the Control Center source, and the glyph is
// iOS's own animated battery package from /System/Library/ControlCenter/Bundles/LowPowerModule.bundle
// (white battery when off, yellow fill on the white selected button when on). iOS ships that bundle on
// iPad too but only loads it on devices that report SupportsLowPowerMode, so this module uses its glyph
// and strings without copying them.

#import <UIKit/UIKit.h>
#import <ControlCenterUIKit/CCUIToggleModule.h>
#import <ControlCenterUIKit/CCUICAPackageDescription.h>

@interface _CDBatterySaver : NSObject
+ (instancetype)batterySaver;
- (long long)getPowerMode;
- (void)setPowerMode:(long long)mode fromSource:(NSString *)source withCompletion:(void (^)(BOOL ok, NSError *error))completion;
@end
extern NSString *const kLPMSourceControlCenter __attribute__((weak_import));

@interface CCUIStatusUpdate : NSObject
+ (instancetype)statusUpdateWithMessage:(NSString *)message type:(unsigned long long)type;
@end
@interface NSObject (BPCCContext)
- (id)contentModuleContext;
- (void)enqueueStatusUpdate:(id)update;
@end

#define kBPStockLowPowerBundle @"/System/Library/ControlCenter/Bundles/LowPowerModule.bundle"

@interface BPLowPowerModule : CCUIToggleModule
@end

@implementation BPLowPowerModule {
    _CDBatterySaver *_saver;
    NSBundle *_stock;
}

- (instancetype)init {
    if ((self = [super init])) {
        _saver = [NSClassFromString(@"_CDBatterySaver") batterySaver];
        _stock = [NSBundle bundleWithPath:kBPStockLowPowerBundle];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(bp_powerStateChanged:) name:NSProcessInfoPowerStateDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)bp_powerStateChanged:(NSNotification *)n {
    dispatch_async(dispatch_get_main_queue(), ^{ [self refreshState]; });
}

- (CCUICAPackageDescription *)glyphPackageDescription {
    if (!_stock) return nil;
    CCUICAPackageDescription *d = [CCUICAPackageDescription descriptionForPackageNamed:@"LowPower" inBundle:_stock];
    d.flipsForRightToLeftLayoutDirection = YES;
    return d;
}

- (NSString *)glyphState {
    return [self isSelected] ? @"enabled" : @"disabled";
}

- (UIColor *)selectedColor {
    return [UIColor systemYellowColor];
}

- (BOOL)isSelected {
    return [NSProcessInfo processInfo].lowPowerModeEnabled;
}

- (void)setSelected:(BOOL)selected {
    if (!_saver) return;
    NSString *source = &kLPMSourceControlCenter ? kLPMSourceControlCenter : @"ControlCenter";
    __weak typeof(self) weakSelf = self;
    [_saver setPowerMode:selected ? 1 : 0 fromSource:source withCompletion:^(BOOL ok, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BPLowPowerModule *me = weakSelf;
            if (!me) return;
            [me refreshState];
            if (!ok) return;
            NSString *key = selected ? @"CONTROL_CENTER_STATUS_LOW_POWER_MODE_ON" : @"CONTROL_CENTER_STATUS_LOW_POWER_MODE_OFF";
            NSString *fallback = selected ? @"Low Power Mode: On" : @"Low Power Mode: Off";
            NSString *msg = me->_stock ? [me->_stock localizedStringForKey:key value:fallback table:nil] : fallback;
            id ctx = [me respondsToSelector:@selector(contentModuleContext)] ? [me contentModuleContext] : nil;
            Class U = NSClassFromString(@"CCUIStatusUpdate");
            if (ctx && U && [ctx respondsToSelector:@selector(enqueueStatusUpdate:)]) [ctx enqueueStatusUpdate:[U statusUpdateWithMessage:msg type:1]];
        });
    }];
}

@end
