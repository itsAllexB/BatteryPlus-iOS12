// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// BatteryPlus status bar: the percentage inside the battery, like modern iOS.
//
// Loaded into every UIKit process, because on iOS 12 each app draws its own status bar.
//
// Which status bar: iOS 12 iPads (checked on an iPad mini 2 in SpringBoard, the lock screen and
// apps) use the classic UIStatusBar, not the iPhone X _UIStatusBar. Control Center is the exception:
// its own status bar, which fades in while it opens, is an iPhone X style _UIStatusBar (see "Control
// Center" below). In the classic one the battery is a UIStatusBarBatteryItemView whose
// -_contentsImage renders an image: the outline image, then
// -[UIStatusBarForegroundStyleAttributes drawBatteryInsidesWithSize:capacity:style:] fills the
// inside with the colour from -batteryColorForCapacity:style:usingTintColor: ("style" is bit 0
// charging, bit 1 Low Power Mode). The "100 %" next to it is a separate item
// (UIStatusBarBatteryPercentItemView), present when Settings > Battery > Battery Percentage is on.
//
// Percentage inside the icon (Settings > Battery > Battery Percentage > Inside Icon): the separate
// percentage item is not shown and the battery draws the number inside itself. The body is a dim
// track and the fill covers the charge level in iOS's own colour for that state. In the status bar's
// colour the digits are cut out of both, so they read on light and dark status bars at every level;
// on yellow, green or red they are drawn in black or white, whichever contrasts more. The charging
// bolt stays beside the battery, as in iOS 12.
//
// Low Power Mode: iOS 12 also turns the "100 %" on whenever Low Power Mode is on
// (-[SBStatusBarStateAggregator _updateBatteryItems:] enables it for Low Power Mode, the Battery
// Percentage switch or the internal showBatteryLevel default). BatteryPlus leaves it to the switch,
// so Low Power Mode only turns the battery yellow. (iOS 12 still shows it on the lock screen while
// iPad is charging; that is left as it is.)
//
// Control Center: it has two _UIStatusBars, a big one while it is open and a small one that takes
// the status bar's place while it closes. Each draws the battery with a _UIBatteryView (in a
// _UIStatusBarBatteryItem), built from layers (body, pin, fill, bolt, a percentage label), with the
// charging bolt inside the battery. With the percentage inside, BatteryPlus hides those layers and
// the item's separate "100 %", and draws the classic status bar's battery item instead: the same
// battery drawing at the same size, in the colours iOS 12 uses there (yellow in Low Power Mode, red
// at 10% or less, green while charging), and while charging the classic bolt next to it (its image,
// gap and offset are read from the classic item). The item gets the classic item's width
// (-intrinsicContentSize), so Control Center lays out its other icons as the status bar does, and
// in the small bar the classic item's right margin (that bar ends its items 1 pt further left).
// Checked on an iPad mini 2 by capturing the closing animation: the small bar's battery, bolt and
// Wi-Fi icon match the status bar pixel for pixel. In the big bar the same item is scaled by the
// ratio of that bar's battery to the classic one.
//
// Nothing polls: UIKit's own battery updates and the BatteryPlus settings notification trigger every
// redraw, and the rendered image stays cached by UIKit.

#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#import <objc/message.h>
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
@property (nonatomic, copy) UIColor *fillColor;
@property (nonatomic, strong) CAShapeLayer *bodyLayer;
@property (nonatomic, strong) CAShapeLayer *pinLayer;
@property (nonatomic, strong) CALayer *fillLayer;
@property (nonatomic, strong) CAShapeLayer *boltLayer;
@property (nonatomic, strong) UILabel *percentageLabel;
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

static BOOL gPercentInside;
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

static BOOL BPSameColor(UIColor *a, UIColor *b) {
    CGFloat r1, g1, b1, a1, r2, g2, b2, a2;
    if (![a getRed:&r1 green:&g1 blue:&b1 alpha:&a1] || ![b getRed:&r2 green:&g2 blue:&b2 alpha:&a2]) return [a isEqual:b];
    return fabs(r1 - r2) < 0.01 && fabs(g1 - g2) < 0.01 && fabs(b1 - b2) < 0.01 && fabs(a1 - a2) < 0.01;
}

// Black or white, whichever contrasts more with c (WCAG relative luminance).
static UIColor *BPContrastColor(UIColor *c) {
    CGFloat rgb[3], a;
    if (![c getRed:&rgb[0] green:&rgb[1] blue:&rgb[2] alpha:&a]) return [UIColor blackColor];
    for (int i = 0; i < 3; i++) rgb[i] = rgb[i] <= 0.03928 ? rgb[i] / 12.92 : pow((rgb[i] + 0.055) / 1.055, 2.4);
    CGFloat l = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
    return (l + 0.05) / 0.05 >= 1.05 / (l + 0.05) ? [UIColor blackColor] : [UIColor whiteColor];
}

// Draws the whole battery (body, fill, number, pin) over the outline's rect {0, 0, size}.
// In the status bar's own colour the number is cut out of the battery. In a state colour (yellow,
// green, red) the background showing through would be hard to read on it, so the number is drawn
// in black or white instead, whichever contrasts more with that colour.
static void BPDrawPercentBattery(CGContextRef ctx, CGSize size, CGFloat pinW, int capacity, UIColor *fill, UIColor *glyph) {
    capacity = MAX(0, MIN(capacity, 100));
    CGRect body = CGRectMake(0, 0, size.width - pinW - 1.0, size.height);
    CGFloat radius = MIN(body.size.height * 0.3, 3.5);
    UIColor *track = [glyph colorWithAlphaComponent:0.35];
    BOOL stateColour = !BPSameColor(fill, glyph);

    CGContextSaveGState(ctx);
    CGContextClearRect(ctx, CGRectMake(-1, -1, size.width + 2, size.height + 2)); // the stock outline
    CGPathRef bodyPath = CGPathCreateWithRoundedRect(body, radius, radius, NULL);
    CGPathRef digits = BPCreateDigitsPath([NSString stringWithFormat:@"%d", capacity], body);
    CGContextAddPath(ctx, bodyPath);
    CGContextClip(ctx);
    CGContextSaveGState(ctx);
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
    if (stateColour && digits) {
        CGContextAddPath(ctx, digits);
        CGContextSetFillColorWithColor(ctx, BPContrastColor(fill).CGColor);
        CGContextFillPath(ctx);
    }
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

#pragma mark - Control Center's battery

static char kBPModernBattery, kBPModernLayer, kBPStockWidth;

// The classic status bar's battery, as SpringBoard lays it out (Control Center runs in SpringBoard),
// so Control Center's battery is drawn the same: the battery image size and pin width (recorded
// when it is drawn), and while charging the bolt next to it (UIStatusBarBatteryItemView's
// _accessoryView: its image, and where it sits relative to the battery).
static CGSize gClassicSize;
static CGFloat gClassicPinW;
static UIImage *gClassicBolt;
static CGSize gClassicBoltSize;
static CGFloat gClassicBoltGap, gClassicBoltDY; // bolt origin relative to the battery image's top right

static UIView *BPAncestor(UIView *v, const char *className) {
    Class c = objc_getClass(className);
    for (UIView *s = v.superview; s && c; s = s.superview)
        if ([s isKindOfClass:c]) return s;
    return nil;
}

// A visible classic battery item, and the bolt metrics from it while it shows one.
static UIStatusBarBatteryItemView *BPClassicBattery(void) {
    UIStatusBarBatteryItemView *found = nil;
    for (UIStatusBarBatteryItemView *v in gBatteryViews.allObjects) {
        if (!v.window || !BPAncestor(v, "UIStatusBar")) continue;
        found = found ?: v;
        Ivar iv = class_getInstanceVariable(object_getClass(v), "_accessoryView");
        UIView *acc = iv ? object_getIvar(v, iv) : nil;
        if (!acc || acc.hidden || acc.superview != v || gClassicSize.width <= 0) continue;
        // A _UILegibilityView: the bolt image fills its frame (plus a legibility shadow, which isn't used).
        id img = [acc respondsToSelector:@selector(image)] ? ((id (*)(id, SEL))objc_msgSend)(acc, @selector(image)) : nil;
        if (![img isKindOfClass:[UIImage class]]) continue;
        gClassicBolt = img;
        gClassicBoltSize = acc.frame.size;
        gClassicBoltGap = acc.frame.origin.x - gClassicSize.width; // the battery image starts at x = 0
        // The battery image is centred vertically in the item, on whole pixels.
        CGFloat sc = v.window.screen.scale ?: [UIScreen mainScreen].scale;
        gClassicBoltDY = acc.frame.origin.y - round((v.bounds.size.height - gClassicSize.height) / 2 * sc) / sc;
        found = v;
    }
    return found;
}

// How much bigger this Control Center status bar draws its battery than the classic one: 1 for the
// small bar that replaces the status bar while Control Center closes, more for the big one.
static CGFloat BPModernScale(CGFloat stockWidth) {
    if (gClassicSize.width <= 0 || stockWidth <= gClassicSize.width + 1) return 1;
    return stockWidth / gClassicSize.width;
}

static BOOL BPModernShowsBolt(_UIBatteryView *b) {
    return b.chargingState != 0 && gClassicBolt && gClassicBoltSize.width > 0;
}

// The battery item's width in the classic status bar: the battery, and while charging the gap and bolt.
static CGFloat BPClassicItemWidth(BOOL bolt) {
    return gClassicSize.width + (bolt ? gClassicBoltGap + gClassicBoltSize.width : 0);
}

// iOS 12's classic iPad status bar colours (see the top of this file).
static UIColor *BPModernFillColor(_UIBatteryView *b, UIColor *glyph) {
    if (b.saverModeActive) return [UIColor systemYellowColor];
    if (b.chargePercent <= 0.10) return [UIColor systemRedColor];
    if (b.chargingState != 0) return [UIColor systemGreenColor];
    return glyph;
}

static void BPUpdateModernBattery(_UIBatteryView *b) {
    if (!objc_getAssociatedObject(b, &kBPModernBattery)) return;
    CALayer *mine = objc_getAssociatedObject(b, &kBPModernLayer);
    BOOL inside = gPercentInside && gClassicSize.width > 0 && [b respondsToSelector:@selector(bodyLayer)] && [b respondsToSelector:@selector(pinLayer)];
    for (NSString *key in @[@"bodyLayer", @"pinLayer", @"fillLayer"])
        if ([b respondsToSelector:NSSelectorFromString(key)]) [[b valueForKey:key] setHidden:inside];
    if ([b respondsToSelector:@selector(boltLayer)] && inside) b.boltLayer.hidden = YES;
    if ([b respondsToSelector:@selector(percentageLabel)] && inside) b.percentageLabel.hidden = YES;
    if (!inside) {
        [mine removeFromSuperlayer];
        objc_setAssociatedObject(b, &kBPModernLayer, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    CGRect body = b.bodyLayer.frame;
    if (CGRectIsEmpty(body) || CGRectIsEmpty(b.bounds)) return;
    UIStatusBarBatteryItemView *classic = BPClassicBattery();
    NSNumber *stock = objc_getAssociatedObject(b, &kBPStockWidth);
    CGFloat k = BPModernScale(stock ? stock.doubleValue : body.size.width);
    BOOL bolt = BPModernShowsBolt(b);
    CGFloat scale = b.window.screen.scale ?: [UIScreen mainScreen].scale;

    // Right edge: the item's own, except in the small bar that takes the status bar's place while
    // Control Center closes. Both bars end at the screen's right edge then, so the battery gets the
    // classic item's right margin (Control Center's small bar ends its items 1 pt further left).
    CGFloat right = CGRectGetMaxX(b.bounds);
    UIView *bar = BPAncestor(b, "_UIStatusBar"), *classicBar = classic ? BPAncestor(classic, "UIStatusBar") : nil;
    if (k == 1 && bar && classicBar) {
        CGFloat classicMargin = CGRectGetWidth(classicBar.bounds) - CGRectGetMaxX([classic convertRect:classic.bounds toView:classicBar]);
        CGFloat ourMargin = CGRectGetWidth(bar.bounds) - [b convertPoint:CGPointMake(right, 0) toView:bar].x;
        if (fabs(ourMargin - classicMargin) <= 4) right += ourMargin - classicMargin;
    }
    // The image spans the battery and the bolt; top is the battery's top inside it.
    CGFloat top = bolt ? MAX(0, -gClassicBoltDY) : 0;
    CGFloat h = MAX(top + gClassicSize.height, bolt ? top + gClassicBoltDY + gClassicBoltSize.height : 0);
    CGSize size = CGSizeMake(BPClassicItemWidth(bolt) * k, h * k);
    CGFloat batteryY = round((CGRectGetMidY(body) - gClassicSize.height * k / 2) * scale) / scale;
    CGRect rect = CGRectMake(round((right - size.width) * scale) / scale, batteryY - top * k, size.width, size.height);

    UIColor *glyph = b.fillColor ?: [UIColor whiteColor];
    UIColor *fill = BPModernFillColor(b, glyph);
    int capacity = (int)lround(b.chargePercent * 100.0);
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextScaleCTM(ctx, k, k);
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, 0, top);
    BPDrawPercentBattery(ctx, gClassicSize, gClassicPinW, capacity, fill, glyph);
    CGContextRestoreGState(ctx);
    if (bolt) {
        // The classic bolt as a mask, in this status bar's colour.
        CGRect r = CGRectMake(gClassicSize.width + gClassicBoltGap, top + gClassicBoltDY, gClassicBoltSize.width, gClassicBoltSize.height);
        UIGraphicsBeginImageContextWithOptions(r.size, NO, scale * k);
        [gClassicBolt drawInRect:(CGRect){CGPointZero, r.size}];
        CGImageRef mask = UIGraphicsGetImageFromCurrentImageContext().CGImage;
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, r.origin.x, r.origin.y + r.size.height);
        CGContextScaleCTM(ctx, 1, -1);
        if (mask) CGContextClipToMask(ctx, (CGRect){CGPointZero, r.size}, mask);
        CGContextSetFillColorWithColor(ctx, glyph.CGColor);
        if (mask) CGContextFillRect(ctx, (CGRect){CGPointZero, r.size});
        CGContextRestoreGState(ctx);
        UIGraphicsEndImageContext();
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!mine) {
        mine = [CALayer layer];
        objc_setAssociatedObject(b, &kBPModernLayer, mine, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (mine.superlayer != b.layer) [b.layer addSublayer:mine];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mine.frame = rect;
    mine.contentsScale = scale;
    mine.contents = (__bridge id)img.CGImage;
    [CATransaction commit];
}

#pragma mark - Refresh

static void BPRefreshBatteries(void) {
    for (UIStatusBarBatteryItemView *v in gBatteryViews.allObjects) {
        [v setCachedImageSet:nil];
        [v updateContentsAndWidth];
    }
}

// Control Center's status bar: the battery drawing and the separate percentage.
static void BPRefreshModern(void) {
    for (_UIStatusBarBatteryItem *item in gModernItems.allObjects) {
        [[item batteryView] invalidateIntrinsicContentSize];
        BPUpdateModernBattery([item batteryView]);
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

%hook UIStatusBarForegroundStyleAttributes

- (void)drawBatteryInsidesWithSize:(CGSize)size capacity:(int)capacity style:(unsigned long long)style {
    UIStatusBarBatteryItemView *v = gDrawingView;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    UIEdgeInsets insets = [self edgeInsetsForBatteryInsides];
    CGFloat pinW = MAX(1.0, insets.right - insets.left - 1.0);
    if (v && (!CGSizeEqualToSize(gClassicSize, size) || gClassicPinW != pinW)) {
        gClassicSize = size;
        gClassicPinW = pinW;
        if (gPercentInside) dispatch_async(dispatch_get_main_queue(), ^{ BPRefreshModern(); });
    }
    if (!v || !ctx || !gPercentInside) {
        %orig;
        return;
    }
    UIColor *glyph = [self tintColor] ?: [UIColor blackColor];
    UIColor *fill = [self batteryColorForCapacity:capacity style:style usingTintColor:YES] ?: glyph;
    BPDrawPercentBattery(ctx, size, pinW, capacity, fill, glyph);
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
        BPUpdateModernBattery(b);
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

// Every change that redraws Control Center's battery redraws BatteryPlus's layer too.
%hook _UIBatteryView

- (void)layoutSubviews {
    %orig;
    BPUpdateModernBattery(self);
}

- (void)setChargePercent:(double)p {
    %orig;
    BPUpdateModernBattery(self);
}

- (void)setChargingState:(long long)s {
    long long old = self.chargingState;
    %orig;
    BPUpdateModernBattery(self);
    // The bolt changes the item's width (see -intrinsicContentSize).
    if (old != s && gPercentInside && objc_getAssociatedObject(self, &kBPModernBattery))
        dispatch_async(dispatch_get_main_queue(), ^{ BPRefreshModern(); });
}

// With the percentage inside, the item is as wide as the classic battery item (with the bolt while
// charging), scaled like the rest of this bar, so Control Center lays out its other items as the
// status bar does.
- (CGSize)intrinsicContentSize {
    CGSize size = %orig;
    if (!objc_getAssociatedObject(self, &kBPModernBattery)) return size;
    objc_setAssociatedObject(self, &kBPStockWidth, @(size.width), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!gPercentInside || gClassicSize.width <= 0) return size;
    BPClassicBattery(); // bolt metrics
    size.width = BPClassicItemWidth(BPModernShowsBolt(self)) * BPModernScale(size.width);
    return size;
}

- (void)setSaverModeActive:(BOOL)a {
    %orig;
    BPUpdateModernBattery(self);
}

- (void)setShowsPercentage:(BOOL)p {
    %orig;
    BPUpdateModernBattery(self);
}

- (void)setShowsInlineChargingIndicator:(BOOL)i {
    %orig;
    BPUpdateModernBattery(self);
}

- (void)setFillColor:(UIColor *)c {
    %orig;
    BPUpdateModernBattery(self);
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

static int gPrefsToken = -1;

static void BPReadPrefs(void) {
    uint64_t v = 0;
    if (gPrefsToken >= 0) notify_get_state(gPrefsToken, &v);
    gPercentInside = BPStatusBarPrefsDecode(v);
}

%ctor {
    @autoreleasepool {
        if (!objc_getClass("UIStatusBarBatteryItemView") || !objc_getClass("UIStatusBarForegroundStyleAttributes")) return;
        gBatteryViews = [NSHashTable weakObjectsHashTable];
        gModernItems = [NSHashTable weakObjectsHashTable];
        notify_register_dispatch(kBPStatusBarStateName, &gPrefsToken, dispatch_get_main_queue(), ^(int t) {
            BOOL p = gPercentInside;
            BPReadPrefs();
            if (p != gPercentInside) { BPRefreshStatusBars(); BPRefreshModern(); }
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
        BPReadPrefs();
        %init;
    }
}
