# Source: packaging/jean-notch.rb in NeilujD/jean-notch. Edit it there, not in the tap:
# each release fills in version and sha256 and pushes it to NeilujD/homebrew-tap.
cask "jean-notch" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/NeilujD/jean-notch/releases/download/v#{version}/JeanNotch-v#{version}.zip"
  name "JeanNotch"
  desc "Notch panel for Jean sessions"
  homepage "https://github.com/NeilujD/jean-notch"

  depends_on macos: :sonoma

  app "JeanNotch.app"

  # The app is ad-hoc signed, not notarized: without this, Gatekeeper refuses to open it.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/JeanNotch.app"]
  end

  uninstall quit: "build.jean.notch"

  zap trash: "~/Library/Preferences/build.jean.notch.plist"
end
