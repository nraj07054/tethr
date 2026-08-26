# Homebrew cask for Tethr.
#
# Lives here so the tap repo (nraj07054/homebrew-tethr) can point at it, or so
# this file can be copied there on each release. Homebrew installs without
# setting the quarantine attribute a browser download would, so the app opens
# without the "damaged" warning that unnotarised apps otherwise produce.
cask "tethr" do
  version "1.0.0"
  # Verified against the v1.0.0 zip. The release workflow prints this digest
  # as a notice, so a new release can be picked up straight from the run log.
  sha256 "10a377a30992134a7b3a3e7cc2b651d46cf1a8c9935a1612c1663911377b18d7"

  url "https://github.com/nraj07054/tethr/releases/download/v#{version}/Tethr-macOS.zip"
  name "Tethr"
  desc "Link an Android phone to your Mac over your own Wi-Fi"
  homepage "https://github.com/nraj07054/tethr"

  # The build is Tahoe-only (LSMinimumSystemVersion 26.0). Without this Homebrew
  # would happily install a binary the machine cannot launch.
  depends_on macos: :tahoe

  app "Tethr.app"

  # Everything Tethr keeps on the Mac: the pairing secret, the accent and theme
  # choice, and window positions. Removed on `brew uninstall --zap`.
  zap trash: [
    "~/Library/Preferences/com.nikhilraj.tethr.plist",
    "~/Library/Saved Application State/com.nikhilraj.tethr.savedState",
  ]
end
