THEOS_PACKAGE_SCHEME = rootless

# Normally inherited from the top-level Makefile; this default only applies
# when the bundle is built on its own.
GI_DEBUG_OPTIONS ?= 1

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = GravityIconsPrefs

GravityIconsPrefs_FILES = GICRootListController.m
GravityIconsPrefs_INSTALL_PATH = /Library/PreferenceBundles
GravityIconsPrefs_FRAMEWORKS = UIKit
GravityIconsPrefs_PRIVATE_FRAMEWORKS = Preferences
GravityIconsPrefs_CFLAGS = -fobjc-arc -DGI_DEBUG_OPTIONS=$(GI_DEBUG_OPTIONS)
GravityIconsPrefs_RESOURCE_FILES = Info.plist resources/Root.plist resources/icon.png resources/icon@2x.png resources/icon@3x.png

include $(THEOS_MAKE_PATH)/bundle.mk
