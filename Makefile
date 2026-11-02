# Switch - macOS menu bar window switcher
# Build system: SPM + shell

.PHONY: build debug test selftest bundle run clean icon dist

BUILD_DIR = .build
APP_BUNDLE = $(BUILD_DIR)/Switch.app

# macOS ties Accessibility permission to the designated requirement. An ad-hoc
# signature's requirement is the cdhash, which changes on every build and would
# silently revoke the permission. Developer ID keeps it stable across builds.
# Development builds skip the secure timestamp, which needs a network request.
# Set your own in local.mk, which git ignores:
#   IDENTITY = Developer ID Application: Your Name (TEAMID)
-include local.mk

# Build a release configuration bundle (not notarized; not a distributable artifact)
build:
	swift build -c release
	@$(MAKE) bundle CONFIG=release

# Build a debug configuration bundle
debug:
	swift build -c debug
	@$(MAKE) bundle CONFIG=debug

run: debug
	@open $(APP_BUNDLE)

test:
	swift test

# Moves only its own fixture windows, but takes focus and the pointer for about a minute.
selftest: debug
	@open -n -W $(APP_BUNDLE) --args --self-test "$(CURDIR)/$(BUILD_DIR)/selftest.json"
	@python3 -I -c "import json,sys; r=json.load(open('$(BUILD_DIR)/selftest.json')); print(r['passed'],'passed,',len(r['failed']),'failed'); [print('FAIL',c['name'],c['detail']) for c in r['failed']]; [print('NOT TESTED',n) for n in r['notTested']]; sys.exit(1 if r['failed'] else 0)"

bundle:
	@test -n "$(IDENTITY)" || { echo "IDENTITY is not set. Add it to local.mk (see the top of this Makefile)."; exit 1; }
	@set -e; \
	CONFIG=$${CONFIG:-debug}; \
	rm -rf $(APP_BUNDLE); \
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources; \
	cp $(BUILD_DIR)/$$CONFIG/SwitchApp $(APP_BUNDLE)/Contents/MacOS/SwitchApp; \
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist; \
	cp Resources/Icon/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns; \
	codesign --force --deep --options runtime --timestamp=none --sign "$(IDENTITY)" $(APP_BUNDLE); \
	echo "Bundle created at $(APP_BUNDLE)"

# Regenerate the checked-in .icns after editing the SVG. Needs rsvg-convert.
icon:
	@set -e; \
	ICONSET=$(BUILD_DIR)/AppIcon.iconset; \
	rm -rf $$ICONSET; mkdir -p $$ICONSET; \
	for size in 16 32 128 256 512; do \
		rsvg-convert -w $$size -h $$size Resources/Icon/AppIcon.svg -o $$ICONSET/icon_$${size}x$${size}.png; \
		rsvg-convert -w $$((size * 2)) -h $$((size * 2)) Resources/Icon/AppIcon.svg -o $$ICONSET/icon_$${size}x$${size}@2x.png; \
	done; \
	iconutil -c icns $$ICONSET -o Resources/Icon/AppIcon.icns

# Signs with a secure timestamp, sends the app to Apple's notary service, and staples the
# ticket. This contacts Apple, so a person runs it. It needs a keychain profile made once with
#   xcrun notarytool store-credentials $(NOTARY_PROFILE)
NOTARY_PROFILE ?= switch-notary
DIST_ZIP = $(BUILD_DIR)/switch-darwin-arm64.zip

dist:
	swift build -c release
	@$(MAKE) bundle CONFIG=release
	codesign --force --deep --options runtime --timestamp --sign "$(IDENTITY)" $(APP_BUNDLE)
	ditto -c -k --keepParent $(APP_BUNDLE) $(DIST_ZIP)
	xcrun notarytool submit $(DIST_ZIP) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(APP_BUNDLE)
	spctl --assess --type execute --verbose $(APP_BUNDLE)
	ditto -c -k --keepParent $(APP_BUNDLE) $(DIST_ZIP)
	@echo "Distributable archive at $(DIST_ZIP)"

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)
