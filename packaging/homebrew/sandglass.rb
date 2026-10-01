# Homebrew cask for the moritzthln/homebrew-tap tap.
#
# `mac/scripts/release.sh` rewrites `version` and `sha256` below after every release build;
# copy the result into Casks/sandglass.rb in the tap.
cask "sandglass" do
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/moritzthln/sandglass/releases/download/v#{version}/Sandglass-#{version}.zip"
  name "Sandglass"
  desc "Calm app and website blocker for the menu bar"
  homepage "https://github.com/moritzthln/sandglass"

  depends_on macos: ">= :sonoma"

  app "Sandglass.app"

  # Sandglass is ad-hoc signed, not notarized, so Gatekeeper would refuse the quarantined copy
  # on first launch. Removing the attribute is the same step the README offers for a manual
  # install.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Sandglass.app"]
  end

  uninstall launchctl: "io.github.moritzthln.sandglass.agent",
            quit:      "io.github.moritzthln.sandglass"

  zap trash: [
    "~/Library/Application Support/Sandglass",
    "~/Library/LaunchAgents/io.github.moritzthln.sandglass.agent.plist",
  ]
end
