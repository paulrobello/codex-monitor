.PHONY: build test lint fmt typecheck checkall generate install install-service restart-service uninstall uninstall-mac uninstall-service uninstall-widgets uninstall-app install-phone launch-phone run refresh clean

PROJECT := CodexMonitor.xcodeproj
SCHEME := CodexMonitor
IOS_SCHEME := CodexMonitoriOS
CONFIGURATION := Debug
BUILD_DIR := build
DERIVED_DATA := build/DerivedData
XCODEBUILD_FLAGS := -allowProvisioningUpdates
APP_NAME := CodexMonitor
SERVICE_PROCESS := net.pardev.CodexMonitor.Service
WIDGET_EXTENSION_PROCESS := CodexMonitorWidgetExtension
WIDGET_BUNDLE_ID := net.pardev.CodexMonitor.Widget
IOS_APP_NAME := CodexMonitoriOS
IOS_BUNDLE_ID := net.pardev.CodexMonitor.iOS
APP_BUNDLE_NAME := $(APP_NAME).app
SERVICE_APP_BUNDLE_NAME := CodexMonitorService.app
APP_BUNDLE := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_BUNDLE_NAME)
SERVICE_APP_BUNDLE := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(SERVICE_APP_BUNDLE_NAME)
IOS_APP_BUNDLE := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/$(IOS_APP_NAME).app
APP_EXTENSION_PATH := Contents/PlugIns/CodexMonitorWidgetExtension.appex
INSTALL_DIR ?= $(HOME)/Applications
INSTALLED_APP_BUNDLE := $(INSTALL_DIR)/$(APP_BUNDLE_NAME)
INSTALLED_APP_EXECUTABLE := $(INSTALLED_APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
INSTALLED_SERVICE_LOGIN_ITEM := $(INSTALLED_APP_BUNDLE)/Contents/Library/LoginItems/$(SERVICE_APP_BUNDLE_NAME)
INSTALLED_WIDGET_EXTENSION := $(INSTALLED_APP_BUNDLE)/$(APP_EXTENSION_PATH)
BUILT_WIDGET_EXTENSION := $(abspath $(APP_BUNDLE))/$(APP_EXTENSION_PATH)
PHONE_DEVICE ?= Pauls iPhone 17
PHONE_DESTINATION ?= platform=iOS,name=$(PHONE_DEVICE)
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

generate:
	xcodegen generate

build: generate
	xcodebuild $(XCODEBUILD_FLAGS) -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -derivedDataPath $(DERIVED_DATA) build

test: generate
	xcodebuild $(XCODEBUILD_FLAGS) -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -derivedDataPath $(DERIVED_DATA) test

lint:
	@echo "No linter configured for this Swift/Xcode project."

fmt:
	@echo "No formatter configured for this Swift/Xcode project."

typecheck: build

checkall: build test lint fmt typecheck

install: build
	pkill -x "$(APP_NAME)" >/dev/null 2>&1 || true
	pkill -x "$(WIDGET_EXTENSION_PROCESS)" >/dev/null 2>&1 || true
	pluginkit -m -A -D -vv | awk 'index($$0, "$(WIDGET_BUNDLE_ID)(") { matched = 1; next } matched && /^[[:space:]]*Path = / { sub(/^[[:space:]]*Path = /, ""); print; matched = 0 }' | while IFS= read -r stale_widget; do \
		pluginkit -r "$$stale_widget" >/dev/null 2>&1 || true; \
	done
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALLED_APP_BUNDLE)"
	ditto "$(APP_BUNDLE)" "$(INSTALLED_APP_BUNDLE)"
	rm -rf "$(INSTALLED_SERVICE_LOGIN_ITEM)"
	mkdir -p "$(dir $(INSTALLED_SERVICE_LOGIN_ITEM))"
	ditto "$(SERVICE_APP_BUNDLE)" "$(INSTALLED_SERVICE_LOGIN_ITEM)"
	"$(LSREGISTER)" -u "$(abspath $(APP_BUNDLE))" >/dev/null 2>&1 || true
	pluginkit -r "$(abspath $(APP_BUNDLE))/$(APP_EXTENSION_PATH)" >/dev/null 2>&1 || true
	"$(LSREGISTER)" -f "$(INSTALLED_APP_BUNDLE)"
	pluginkit -a "$(INSTALLED_APP_BUNDLE)/$(APP_EXTENSION_PATH)" >/dev/null 2>&1 || true
	pkill -x "$(WIDGET_EXTENSION_PROCESS)" >/dev/null 2>&1 || true

install-service: install
	pkill -f "$(SERVICE_PROCESS)" >/dev/null 2>&1 || true
	"$(INSTALLED_APP_EXECUTABLE)" --register-service

restart-service: install-service

uninstall: uninstall-service uninstall-widgets uninstall-app

uninstall-mac: uninstall

uninstall-service:
	@if [ -x "$(INSTALLED_APP_EXECUTABLE)" ]; then \
		"$(INSTALLED_APP_EXECUTABLE)" --unregister-service; \
	else \
		echo "$(INSTALLED_APP_EXECUTABLE) is missing; skipping service unregister."; \
	fi
	pkill -f "$(SERVICE_PROCESS)" >/dev/null 2>&1 || true

uninstall-widgets:
	pkill -x "$(WIDGET_EXTENSION_PROCESS)" >/dev/null 2>&1 || true
	pluginkit -m -A -D -vv | awk 'index($$0, "$(WIDGET_BUNDLE_ID)(") { matched = 1; next } matched && /^[[:space:]]*Path = / { sub(/^[[:space:]]*Path = /, ""); print; matched = 0 }' | while IFS= read -r stale_widget; do \
		pluginkit -r "$$stale_widget" >/dev/null 2>&1 || true; \
	done
	pluginkit -r "$(INSTALLED_WIDGET_EXTENSION)" >/dev/null 2>&1 || true
	pluginkit -r "$(BUILT_WIDGET_EXTENSION)" >/dev/null 2>&1 || true

uninstall-app:
	pkill -x "$(APP_NAME)" >/dev/null 2>&1 || true
	"$(LSREGISTER)" -u "$(INSTALLED_APP_BUNDLE)" >/dev/null 2>&1 || true
	rm -rf "$(INSTALLED_APP_BUNDLE)"

install-phone: generate
	xcodebuild $(XCODEBUILD_FLAGS) -project $(PROJECT) -scheme $(IOS_SCHEME) -configuration $(CONFIGURATION) -derivedDataPath $(DERIVED_DATA) -destination '$(PHONE_DESTINATION)' build
	xcrun devicectl device install app --device "$(PHONE_DEVICE)" "$(IOS_APP_BUNDLE)"

launch-phone: install-phone
	xcrun devicectl device process launch --device "$(PHONE_DEVICE)" --terminate-existing $(IOS_BUNDLE_ID)

run: install
	/usr/bin/open "$(INSTALLED_APP_BUNDLE)"

refresh: build
	DYLD_FRAMEWORK_PATH="$(DERIVED_DATA)/Build/Products/Debug" "$(DERIVED_DATA)/Build/Products/Debug/codex-usage" refresh

clean:
	rm -rf "$(BUILD_DIR)" "$(PROJECT)"
