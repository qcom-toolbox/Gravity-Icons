ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GravityIcons

GravityIcons_FILES = Tweak.xm GravityManager.m
GravityIcons_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
GravityIcons_FRAMEWORKS = UIKit CoreMotion QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += gravityiconsprefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "sbreload"
