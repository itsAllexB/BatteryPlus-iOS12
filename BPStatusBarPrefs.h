// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// The status bar settings reach every app through a notify state, because sandboxed apps can't
// read BatteryPlus's preferences. SpringBoard (and Settings, when a switch changes) read the
// preferences and publish them as the state of kBPStatusBarStateName; each process reads that state
// once and again whenever it is posted.

#import <Foundation/Foundation.h>
#include <notify.h>

#define kBPStatusBarStateName "com.itsallexb.batteryplus.statusbar"
#define kBPPrefsChangedName "com.itsallexb.batteryplus/prefschanged"
#define kBPPrefsDomain CFSTR("com.itsallexb.batteryplus")

// bit 8: state is valid; bit 1: Percentage Inside Icon. (Bit 0 was Battery Colours, before 1.2.0.)
static inline BOOL BPStatusBarPrefsDecode(uint64_t v) {
    return (v & 0x100) && (v & 2); // off by default
}

static inline BOOL BPPrefsBool(CFStringRef key, BOOL def) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, kBPPrefsDomain);
    BOOL r = def;
    if (v && CFGetTypeID(v) == CFBooleanGetTypeID()) r = CFBooleanGetValue((CFBooleanRef)v);
    else if (v && CFGetTypeID(v) == CFNumberGetTypeID()) { int i = 0; CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &i); r = i != 0; }
    if (v) CFRelease(v);
    return r;
}

static inline void BPStatusBarPrefsPublish(void) {
    CFPreferencesAppSynchronize(kBPPrefsDomain);
    uint64_t v = 0x100 | (BPPrefsBool(CFSTR("sbPercentInside"), NO) ? 2 : 0);
    int t;
    if (notify_register_check(kBPStatusBarStateName, &t) == NOTIFY_STATUS_OK) {
        uint64_t old = 0;
        notify_get_state(t, &old);
        notify_set_state(t, v);
        notify_cancel(t);
        if (old != v) notify_post(kBPStatusBarStateName);
    }
}
