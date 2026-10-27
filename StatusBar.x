// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// BatteryPlus status bar: battery colours and the percentage inside the battery, like current iOS.
//
// Loaded into every UIKit process, because on iOS 12 each app draws its own status bar.
//
// Which status bar: iOS 12 iPads (checked on an iPad mini 2 in SpringBoard, the lock screen,
// Control Center and apps) use the classic UIStatusBar, not the iPhone X _UIStatusBar. The battery
// is a UIStatusBarBatteryItemView whose -_contentsImage renders an image: the outline image, then
// -[UIStatusBarForegroundStyleAttributes drawBatteryInsidesWithSize:capacity:style:] fills the
// inside with the colour from -_batteryColorForCapacity:lowCapacity:style:usingTintColor:. "style" is
// bit 0 charging, bit 1 Low Power Mode. The "100 %" next to it is a separate item
// (UIStatusBarBatteryPercentItemView), present when Settings > Battery > Battery Percentage is on.
//
// Colours (when "Battery Colours" is on), in this order, as on iOS 16 and later:
//   Low Power Mode   yellow (also while charging)
//   charging         green
//   20% or less      red
//   otherwise        the status bar's own colour (white or black)
// iOS 12 itself uses: Low Power Mode yellow, then red at 10% on iPad (20% on iPhone) even while
// charging, then green while charging. With the option off, that stock behaviour is untouched.
//
// Percentage inside the icon (when that option and Battery Percentage are on): the separate
// percentage item is not shown and the battery draws the number inside itself. The body is a dim
// track, the fill covers the charge level in the colour above, and the digits are cut out of both,
// so they read on light and dark status bars at every level. The charging bolt stays beside the
// battery, as in iOS 12.
//
// Nothing polls: UIKit's own battery updates, the Low Power Mode notification and the BatteryPlus
// settings notification trigger every redraw, and the rendered image stays cached by UIKit.

#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#include <notify.h>
#import "BPStatusBarPrefs.h"

@interface UIStatusBarComposedData : NSObject
- (BOOL)isItemEnabled:(int)type;
@end
@interface UIStatusBarItem : NSObject
+ (instancetype)itemWithType:(int)type idiom:(long long)idiom;
- (Class)viewClass;
@end
@interface UIStatusBarForegroundStyleAttributes : NSObject
- (UIColor *)tintColor;
- (UIEdgeInsets)edgeInsetsForBatteryInsides;
- (UIColor *)batteryColorForCapacity:(int)capacity style:(unsigned long long)style usingTintColor:(BOOL)tint;
@end
@interface UIStatusBarItemView : UIView
- (void)updateContentsAndWidth;
@end
@interface UIStatusBarBatteryItemView : UIStatusBarItemView
- (void)setCachedImageSet:(id)set;
@end
@interface UIView (BPStatusBar)
- (void)forceUpdateToData:(const void *)rawData animated:(BOOL)animated;
@end

#pragma mark - State

static BOOL gColors = YES, gPercentInside = NO, gLowPower;
static int gPercentItemType = -1;
static NSHashTable *gBatteryViews;
static __weak UIStatusBarBatteryItemView *gDrawingView; // the battery whose image is being rendered

static BOOL gPercentSettingOn; // Battery Percentage is on (UIKit would show the percentage item)

static BOOL BPWantsPercentInside(void) {
    return gPercentInside && gPercentSettingOn;
}

static int BPPercentItemType(void) {
    if (gPercentItemType == -1) {
        gPercentItemType = -2;
        Class pct = objc_getClass("UIStatusBarBatteryPercentItemView");
        for (int t = 0; t < 64 && pct; t++) {
            UIStatusBarItem *item = [objc_getClass("UIStatusBarItem") itemWithType:t idiom:UIUserInterfaceIdiomPad];
            if (item && [item viewClass] == pct) { gPercentItemType = t; break; }
        }
    }
    return gPercentItemType;
}

#pragma mark - Percentage inside the battery

// The digits as a path, centred in rect and narrowed if they do not fit.
static CGPathRef BPCreateDigitsPath(NSString *text, CGRect rect) {
    CGFloat size = rect.size.height;
    UIFont *font = [UIFont systemFontOfSize:size weight:UIFontWeightBold];
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:text attributes:@{(id)kCTFontAttributeName: font}];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
    CGMutablePathRef glyphs = CGPathCreateMutable();
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex r = 0; r < CFArrayGetCount(runs); r++) {
        CTRunRef run = CFArrayGetValueAtIndex(runs, r);
        CTFontRef runFont = CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        CFIndex n = CTRunGetGlyphCount(run);
        if (n <= 0) continue;
        CGGlyph g[n]; CGPoint p[n];
        CTRunGetGlyphs(run, CFRangeMake(0, n), g);
        CTRunGetPositions(run, CFRangeMake(0, n), p);
        for (CFIndex i = 0; i < n; i++) {
            CGAffineTransform t = CGAffineTransformMakeTranslation(p[i].x, p[i].y);
            CGPathRef gp = CTFontCreatePathForGlyph(runFont, g[i], &t);
            if (gp) { CGPathAddPath(glyphs, NULL, gp); CGPathRelease(gp); }
        }
    }
    CFRelease(line);
    // Fit the digits' own bounds (not the line box) into the body, centred, flipped into UIKit
    // coordinates. Wide numbers ("100") are narrowed instead of made smaller.
    CGRect gb = CGPathGetPathBoundingBox(glyphs);
    CGFloat availW = rect.size.width - 3.0, availH = rect.size.height - 3.5;
    CGFloat sy = availH / MAX(gb.size.height, 0.01), sx = sy;
    if (gb.size.width * sx > availW) sx = availW / gb.size.width;
    CGAffineTransform t = CGAffineTransformMakeTranslation(CGRectGetMidX(rect), CGRectGetMidY(rect));
    t = CGAffineTransformScale(t, sx, -sy);
    t = CGAffineTransformTranslate(t, -CGRectGetMidX(gb), -CGRectGetMidY(gb));
    CGPathRef out = CGPathCreateCopyByTransformingPath(glyphs, &t);
    CGPathRelease(glyphs);
    return out;
}

// Draws the whole battery (body, fill, number, pin) over the outline's rect {0, 0, size}.
static void BPDrawPercentBattery(CGContextRef ctx, CGSize size, UIEdgeInsets insets, int capacity, UIColor *fill, UIColor *glyph) {
    capacity = MAX(0, MIN(capacity, 100));
    CGFloat pinW = MAX(1.0, insets.right - insets.left - 1.0);
    CGRect body = CGRectMake(0, 0, size.width - pinW - 1.0, size.height);
    CGFloat radius = MIN(body.size.height * 0.3, 3.5);
    UIColor *track = [glyph colorWithAlphaComponent:0.35];

    CGContextSaveGState(ctx);
    CGContextClearRect(ctx, CGRectMake(-1, -1, size.width + 2, size.height + 2)); // the stock outline
    CGPathRef bodyPath = CGPathCreateWithRoundedRect(body, radius, radius, NULL);
    CGPathRef digits = BPCreateDigitsPath([NSString stringWithFormat:@"%d", capacity], body);
    CGContextAddPath(ctx, bodyPath);
    CGContextClip(ctx);
    // Body minus the digits (even-odd), so the number is cut out of the track and the fill.
    CGContextAddRect(ctx, CGRectInset(body, -2, -2));
    if (digits) CGContextAddPath(ctx, digits);
    CGContextEOClip(ctx);
    CGContextSetFillColorWithColor(ctx, track.CGColor);
    CGContextFillRect(ctx, body);
    CGFloat w = body.size.width * capacity / 100.0;
    if (capacity > 0) w = MAX(w, 1.5);
    CGContextSetFillColorWithColor(ctx, fill.CGColor);
    CGContextFillRect(ctx, CGRectMake(body.origin.x, body.origin.y, w, body.size.height));
    CGContextRestoreGState(ctx);
    CGPathRelease(bodyPath);
    if (digits) CGPathRelease(digits);

    CGFloat pinH = round(size.height * 0.36 * 2) / 2;
    CGRect pin = CGRectMake(CGRectGetMaxX(body) + 1.0, (size.height - pinH) / 2, pinW, pinH);
    UIBezierPath *pinPath = [UIBezierPath bezierPathWithRoundedRect:pin byRoundingCorners:UIRectCornerTopRight | UIRectCornerBottomRight cornerRadii:CGSizeMake(pinW, pinW)];
    CGContextSetFillColorWithColor(ctx, (capacity >= 100 ? fill : track).CGColor);
    CGContextAddPath(ctx, pinPath.CGPath);
    CGContextFillPath(ctx);
}

#pragma mark - Refresh

static void BPRefreshBatteries(void) {
    for (UIStatusBarBatteryItemView *v in gBatteryViews.allObjects) {
        [v setCachedImageSet:nil];
        [v updateContentsAndWidth];
    }
}

// The percentage item comes and goes with the setting, so the status bars re-run their layout.
static void BPRefreshStatusBars(void) {
    NSMutableSet *bars = [NSMutableSet set];
    for (UIStatusBarBatteryItemView *v in gBatteryViews.allObjects) {
        for (UIView *s = v.superview; s; s = s.superview)
            if ([s isKindOfClass:objc_getClass("UIStatusBar")] && [s respondsToSelector:@selector(forceUpdateToData:animated:)]) { [bars addObject:s]; break; }
    }
    BPRefreshBatteries();
    // With NULL, UIStatusBar hands its current data to its foreground view again, which recomputes
    // the visible items.
    for (UIView *bar in bars) [bar forceUpdateToData:NULL animated:NO];
}

#pragma mark - Hooks

%hook UIStatusBarForegroundStyleAttributes

- (UIColor *)_batteryColorForCapacity:(int)capacity lowCapacity:(int)low style:(unsigned long long)style usingTintColor:(BOOL)tint {
    if (!gColors) return %orig;
    if (gLowPower) style |= 2;
    if (style & 2) return %orig(capacity, low, 2, tint);   // yellow, also while charging
    if (style & 1) return %orig(capacity, -1, 1, tint);    // green while charging, whatever the level
    return %orig(capacity, 20, 0, tint);                    // red at 20% or less, else the tint
}

- (void)drawBatteryInsidesWithSize:(CGSize)size capacity:(int)capacity style:(unsigned long long)style {
    UIStatusBarBatteryItemView *v = gDrawingView;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!v || !ctx || !BPWantsPercentInside()) {
        %orig;
        return;
    }
    if (gLowPower && gColors) style |= 2;
    UIColor *glyph = [self tintColor] ?: [UIColor blackColor];
    UIColor *fill = [self batteryColorForCapacity:capacity style:style usingTintColor:YES] ?: glyph;
    BPDrawPercentBattery(ctx, size, [self edgeInsetsForBatteryInsides], capacity, fill, glyph);
}

%end

%hook UIStatusBarBatteryItemView

- (id)_contentsImage {
    [gBatteryViews addObject:self];
    gDrawingView = self;
    id r = %orig;
    gDrawingView = nil;
    return r;
}

%end

%hook UIStatusBarItem

// Hide the separate "100 %" while the number is drawn inside the battery.
// This is where UIKit decides whether the percentage item is shown, so it also tells the battery
// whether Battery Percentage is on.
+ (BOOL)itemType:(int)type idiom:(long long)idiom canBeEnabledForData:(UIStatusBarComposedData *)data style:(id)style {
    BOOL r = %orig;
    if (type != BPPercentItemType()) return r;
    if (r != gPercentSettingOn) {
        gPercentSettingOn = r;
        if (gPercentInside) dispatch_async(dispatch_get_main_queue(), ^{ BPRefreshBatteries(); });
    }
    return gPercentInside ? NO : r;
}

%end

#pragma mark - Setup

static int gLPMToken = -1, gPrefsToken = -1;

static void BPReadLowPower(void) {
    uint64_t v = 0;
    if (gLPMToken >= 0) notify_get_state(gLPMToken, &v);
    gLowPower = v != 0;
}

static void BPReadPrefs(void) {
    uint64_t v = 0;
    if (gPrefsToken >= 0) notify_get_state(gPrefsToken, &v);
    BPStatusBarPrefsDecode(v, &gColors, &gPercentInside);
}

%ctor {
    @autoreleasepool {
        if (!objc_getClass("UIStatusBarBatteryItemView") || !objc_getClass("UIStatusBarForegroundStyleAttributes")) return;
        gBatteryViews = [NSHashTable weakObjectsHashTable];
        notify_register_dispatch(kBPStatusBarStateName, &gPrefsToken, dispatch_get_main_queue(), ^(int t) {
            BOOL c = gColors, p = gPercentInside;
            BPReadPrefs();
            if (p != gPercentInside) BPRefreshStatusBars();
            else if (c != gColors) BPRefreshBatteries();
        });
        // SpringBoard publishes the settings for every app (sandboxed apps can't read our preferences).
        // notifyd keeps a state only while someone is registered for the name, so this comes after
        // SpringBoard's own registration above, which lives as long as SpringBoard.
        if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            BPStatusBarPrefsPublish();
            int t;
            notify_register_dispatch(kBPPrefsChangedName, &t, dispatch_get_main_queue(), ^(int x) { BPStatusBarPrefsPublish(); });
        }
        notify_register_dispatch("com.apple.system.batterysavermode", &gLPMToken, dispatch_get_main_queue(), ^(int t) {
            BOOL old = gLowPower;
            BPReadLowPower();
            if (old != gLowPower) BPRefreshBatteries();
        });
        BPReadPrefs();
        BPReadLowPower();
        %init;
    }
}
