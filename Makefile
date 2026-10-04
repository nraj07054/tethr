.PHONY: all mac dmg android install install-mac install-android test clean

all: mac android

mac:            ## Build Tethr.app
	@scripts/build-mac.sh

dmg:            ## Build Tethr.app and package it as Tethr-macOS.dmg
	@scripts/build-dmg.sh

android:        ## Build the Android APK
	@cd android && ./gradlew assembleDebug

install: install-mac install-android  ## Build and install both ends

install-mac:    ## Build and install Tethr.app to /Applications
	@scripts/install-mac.sh

install-android:  ## Build and install the app on a connected phone
	@scripts/install-android.sh

test:           ## Run the wire-format tests
	@cd android && ./gradlew testDebugUnitTest

clean:
	@rm -rf mac/.build android/app/build android/build
