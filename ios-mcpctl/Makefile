ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
    TARGET := iphone:clang:latest:15.0
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
    TARGET := iphone:clang:latest:15.0
else
    TARGET := iphone:clang:latest:13.0
endif
ARCHS = arm64 arm64e
DEBUG = 0

include $(THEOS)/makefiles/common.mk

TOOL_NAME = ios-mcpctl
ios-mcpctl_FILES = main.m
ios-mcpctl_CFLAGS = -fobjc-arc -Wall -Wextra
ios-mcpctl_FRAMEWORKS = Foundation CoreFoundation
ios-mcpctl_INSTALL_PATH = /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
