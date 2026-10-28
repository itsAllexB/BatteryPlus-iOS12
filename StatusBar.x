// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// BatteryPlus status bar: battery colours and the percentage inside the battery, like modern iOS.
//
// Loaded into every UIKit process, because on iOS 12 each app draws its own status bar.
//
// Which status bar: iOS 12 iPads (checked on an iPad mini 2 in SpringBoard, the lock screen and
// apps) use the classic UIStatusBar, not the iPhone X _UIStatusBar. Control Center is the exception:
// its own status bar, which fades in while it opens, is an iPhone X style _UIStatusBar (see "Control
// Center" below). In the classic one the battery
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
// Percentage inside the icon (when that option is on, whether or not Battery Percentage is): the
// separate percentage item is not shown and the battery draws the number inside itself. The body is a dim
// track, the fill covers the charge level in the colour above, and the digits are cut out of both,
// so they read on light and dark status bars at every level. The charging bolt stays beside the
// battery, as in iOS 12.
//
// Low Power Mode: iOS 12 also turns the "100 %" on whenever Low Power Mode is on
// (-[SBStatusBarStateAggregator _updateBatteryItems:] enables it for Low Power Mode, the Battery
// Percentage switch or the internal showBatteryLevel default). BatteryPlus leaves it to the switch,
// so Low Power Mode only turns the battery yellow. (iOS 12 still shows it on the lock screen while
// iPad is charging; that is left as it is.)
//
// Control Center: its _UIStatusBar draws the battery with a _UIBatteryView (in a
// _UIStatusBarBatteryItem), which on iOS 12 can already draw the number inside itself
// (showsPercentage). BatteryPlus turns that on and hides the item's separate "100 %" when the
// percentage is inside, and gives the fill the same colours as above. Without this, Control
// Center's battery switched back to the iOS 12 look while it opened.
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
@interface SBStatusBarDefaults : NSObject
- (BOOL)showBatteryPercentage;
- (BOOL)showBatteryLevel;
@end
@interface BSPlatform : NSObject
+ (instancetype)sharedInstance;
- (BOOL)hasGasGauge;
@end
@interface _UIBatteryView : UIView
@property (nonatomic) BOOL showsPercentage;
@property (nonatomic) double chargePercent;
@property (nonatomic) long long chargingState;
@property (nonatomic) BOOL saverModeActive;
@property (nonatomic) BOOL showsInlineChargingIndicator;
- (void)_updateFillColor;
@end
@interface _UIStatusBar : UIView
- (void)updateWithAnimations:(NSArray *)animations;
@end
@interface _UIStatusBarItem : NSObject
- (_UIStatusBar *)statusBar;
- (void)setNeedsUpdate;
@end
@interface _UIStatusBarBatteryItem : _UIStatusBarItem
+ (id)percentDisplayIdentifier;
- (_UIBatteryView *)batteryView;
@end
@interface UIView (BPStatusBar)
- (void)forceUpdateToData:(const void *)rawData animated:(BOOL)animated;
@end

#pragma mark - State

static BOOL gColors = YES, gPercentInside = NO, gLowPower;
static int gPercentItemType = -1;
static NSHashTable *gBatteryViews;
static NSHashTable *gModernItems; // Control Center's _UIStatusBarBatteryItems
static __weak UIStatusBarBatteryItemView *gDrawingView; // the battery whose image is being rendered

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

// Control Center's status bar: the number inside, the separate percentage on or off, the fill colour.
static void BPRefreshModern(void) {
    for (_UIStatusBarBatteryItem *item in gModernItems.allObjects) {
        _UIBatteryView *b = [item batteryView];
        if ([b respondsToSelector:@selector(setShowsPercentage:)]) b.showsPercentage = gPercentInside;
        if ([b respondsToSelector:@selector(_updateFillColor)]) [b _updateFillColor];
        [item setNeedsUpdate];
        _UIStatusBar *bar = [item statusBar];
        if ([bar respondsToSelector:@selector(updateWithAnimations:)]) [bar updateWithAnimations:@[]];
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

static char kBPModernBattery;

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
    if (!v || !ctx || !gPercentInside) {
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

// Hide the separate "100 %" while the number is drawn inside the battery. This is where UIKit
// decides whether the percentage item is shown (Battery Percentage on, or Low Power Mode).
+ (BOOL)itemType:(int)type idiom:(long long)idiom canBeEnabledForData:(UIStatusBarComposedData *)data style:(id)style {
    if (gPercentInside && type == BPPercentItemType()) return NO;
    return %orig;
}

%end

%hook _UIStatusBarBatteryItem

- (id)applyUpdate:(id)update toDisplayItem:(id)displayItem {
    id r = %orig;
    [gModernItems addObject:self];
    _UIBatteryView *b = [self batteryView];
    if (b) {
        objc_setAssociatedObject(b, &kBPModernBattery, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if ([b respondsToSelector:@selector(setShowsPercentage:)] && b.showsPercentage != gPercentInside) b.showsPercentage = gPercentInside;
        if (gPercentInside && [b respondsToSelector:@selector(showsInlineChargingIndicator)] && b.showsInlineChargingIndicator)
            b.showsInlineChargingIndicator = NO;
    }
    return r;
}

// The separate "100 %" next to the battery.
- (BOOL)canEnableDisplayItem:(id)displayItem fromData:(id)data {
    if (gPercentInside && [displayItem respondsToSelector:@selector(identifier)]
        && [[displayItem identifier] isEqual:[[self class] percentDisplayIdentifier]])
        return NO;
    return %orig;
}

%end

%hook _UIBatteryView

// iOS 12 draws the bolt instead of the number while charging. With the number inside, the number
// stays and the green fill shows charging. (Control Center's iPad status bar has no separate bolt
// next to the battery, unlike the classic status bar.)
- (void)setShowsInlineChargingIndicator:(BOOL)inlineBolt {
    if (gPercentInside && objc_getAssociatedObject(self, &kBPModernBattery)) inlineBolt = NO;
    %orig(inlineBolt);
}

- (BOOL)_currentlyShowsPercentage {
    if (gPercentInside && objc_getAssociatedObject(self, &kBPModernBattery)) return YES;
    return %orig;
}

- (UIColor *)_batteryFillColor {
    if (!gColors || !objc_getAssociatedObject(self, &kBPModernBattery)) return %orig;
    if (self.saverModeActive || gLowPower) return [UIColor systemYellowColor]; // also while charging
    if (self.chargingState != 0) return [UIColor systemGreenColor];          // whatever the level
    if (self.chargePercent <= 0.20) return [UIColor systemRedColor];
    return %orig;
}

%end

// SpringBoard only: Low Power Mode doesn't force the percentage on (see the top of this file).
%group SpringBoard
%hook SBStatusBarStateAggregator

- (BOOL)_setItem:(int)item enabled:(BOOL)enabled {
    if (enabled && item == BPPercentItemType()) {
        Ivar iv = class_getInstanceVariable(object_getClass(self), "_statusBarDefaults");
        SBStatusBarDefaults *d = iv ? object_getIvar(self, iv) : nil;
        BSPlatform *platform = [objc_getClass("BSPlatform") sharedInstance];
        if ([d respondsToSelector:@selector(showBatteryPercentage)] && [d respondsToSelector:@selector(showBatteryLevel)]
            && [platform respondsToSelector:@selector(hasGasGauge)] && [platform hasGasGauge]
            && ![d showBatteryPercentage] && ![d showBatteryLevel])
            enabled = NO;
    }
    return %orig(item, enabled);
}

%end
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
        gModernItems = [NSHashTable weakObjectsHashTable];
        notify_register_dispatch(kBPStatusBarStateName, &gPrefsToken, dispatch_get_main_queue(), ^(int t) {
            BOOL c = gColors, p = gPercentInside;
            BPReadPrefs();
            if (p != gPercentInside) BPRefreshStatusBars();
            else if (c != gColors) BPRefreshBatteries();
            if (p != gPercentInside || c != gColors) BPRefreshModern();
        });
        // SpringBoard publishes the settings for every app (sandboxed apps can't read our preferences).
        // notifyd keeps a state only while someone is registered for the name, so this comes after
        // SpringBoard's own registration above, which lives as long as SpringBoard.
        if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            if (objc_getClass("SBStatusBarStateAggregator")) %init(SpringBoard);
            BPStatusBarPrefsPublish();
            int t;
            notify_register_dispatch(kBPPrefsChangedName, &t, dispatch_get_main_queue(), ^(int x) { BPStatusBarPrefsPublish(); });
        }
        notify_register_dispatch("com.apple.system.batterysavermode", &gLPMToken, dispatch_get_main_queue(), ^(int t) {
            BOOL old = gLowPower;
            BPReadLowPower();
            if (old != gLowPower) { BPRefreshBatteries(); BPRefreshModern(); }
        });
        BPReadPrefs();
        BPReadLowPower();
        %init;
    }
}
