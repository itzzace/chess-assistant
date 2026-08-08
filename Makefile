ARCHS = arm64
TARGET = iphone:clang:latest:15.0

THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Chess

Chess_FILES      = Tweak.xm engine.mm maia.mm
Chess_FRAMEWORKS = UIKit Foundation QuartzCore CoreML
Chess_LIBRARIES  = substrate
Chess_CFLAGS     = -fobjc-arc -Wno-deprecated-declarations -Isf/src -std=c++17
Chess_LDFLAGS    = -Lsf/src -lstockfish -lc++

include $(THEOS)/makefiles/tweak.mk
