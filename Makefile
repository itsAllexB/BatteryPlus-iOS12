# SPDX-License-Identifier: GPL-3.0-or-later
TARGET := iphone:clang:14.5:12.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = Preferences SpringBoard
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = xz
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

# Settings > Battery (Preferences only)
TWEAK_NAME = BatteryPlus BatteryPlusStatusBar
BatteryPlus_FILES = Tweak.x BPBattery.m BPControllers.m
BatteryPlus_FRAMEWORKS = UIKit IOKit
BatteryPlus_PRIVATE_FRAMEWORKS = Preferences
BatteryPlus_CFLAGS = -fobjc-arc

# Status bar battery (every UIKit process)
BatteryPlusStatusBar_FILES = StatusBar.x
BatteryPlusStatusBar_FRAMEWORKS = UIKit CoreText QuartzCore
BatteryPlusStatusBar_CFLAGS = -fobjc-arc

TOOL_NAME = batteryplusd
batteryplusd_FILES = daemon/main.m
batteryplusd_FRAMEWORKS = Foundation IOKit CoreFoundation
batteryplusd_CFLAGS = -fobjc-arc
batteryplusd_CODESIGN_FLAGS = -Sdaemon/entitlements.plist
batteryplusd_INSTALL_PATH = /usr/libexec

SUBPROJECTS += ccmodule

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
