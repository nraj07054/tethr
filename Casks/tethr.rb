# Homebrew cask for Tethr.
#
# Lives here so the tap repo (nraj07054/homebrew-tethr) can point at it, or so
# this file can be copied there on each release. Homebrew installs without
# setting the quarantine attribute a browser download would, so the app opens
# without the "damaged" warning that unnotarised apps otherwise produce.
cask "tethr" do
  version "1.1.2"
  # Verified against the v1.1.2 zip. The release workflow prints this digest
  # as a notice, so a new release can be picked up straight from the run log.
  sha256 "a430ec7b61d3e50b167030473e2d7e21f2f79cafaa2e9974b9ffb85317203413"

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
