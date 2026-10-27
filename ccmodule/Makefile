# SPDX-License-Identifier: GPL-3.0-or-later
TARGET := iphone:clang:14.5:12.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = BatteryPlusLowPower
BatteryPlusLowPower_BUNDLE_EXTENSION = bundle
BatteryPlusLowPower_FILES = BPLowPowerModule.m
BatteryPlusLowPower_CFLAGS = -fobjc-arc
BatteryPlusLowPower_FRAMEWORKS = UIKit
BatteryPlusLowPower_PRIVATE_FRAMEWORKS = ControlCenterUIKit CoreDuet
BatteryPlusLowPower_INSTALL_PATH = /Library/ControlCenter/Bundles

include $(THEOS_MAKE_PATH)/bundle.mk
