THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = GravityIconsPrefs

GravityIconsPrefs_FILES = GICRootListController.m
GravityIconsPrefs_INSTALL_PATH = /Library/PreferenceBundles
GravityIconsPrefs_FRAMEWORKS = UIKit
GravityIconsPrefs_PRIVATE_FRAMEWORKS = Preferences
GravityIconsPrefs_CFLAGS = -fobjc-arc
GravityIconsPrefs_RESOURCE_FILES = Info.plist resources/Root.plist resources/icon.png

include $(THEOS_MAKE_PATH)/bundle.mk
