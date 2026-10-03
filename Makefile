ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless

# Debug-only options (the Show Border Outline switch): included in normal
# builds, stripped from release builds (FINALPACKAGE=1). Override with
# GI_DEBUG_OPTIONS=0 or GI_DEBUG_OPTIONS=1. Run `make clean` after
# overriding it within the same build mode — Theos doesn't rebuild objects
# when only a flag changes.
ifeq ($(FINALPACKAGE),1)
GI_DEBUG_OPTIONS ?= 0
else
GI_DEBUG_OPTIONS ?= 1
endif
export GI_DEBUG_OPTIONS

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GravityIcons

GravityIcons_FILES = Tweak.xm GravityManager.m
GravityIcons_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -DGI_DEBUG_OPTIONS=$(GI_DEBUG_OPTIONS)
GravityIcons_FRAMEWORKS = UIKit CoreMotion QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += gravityiconsprefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "sbreload"
