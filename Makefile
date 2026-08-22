TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FightVoicePro
FightVoicePro_FILES = Tweak.x
FightVoicePro_CFLAGS = -fobjc-arc -O3 -Wno-error -Wno-deprecated-declarations
FightVoicePro_FRAMEWORKS = UIKit Foundation CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk
