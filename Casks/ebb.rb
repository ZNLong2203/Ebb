cask "ebb" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/ZNLong2203/Ebb/releases/download/v#{version}/Ebb-#{version}.zip"
  name "Ebb"
  desc "Developer-aware disk cleaner: caches, node_modules, Docker, Xcode and large files"
  homepage "https://github.com/ZNLong2203/Ebb"

  depends_on macos: :sonoma
  depends_on arch: :arm64

  app "Ebb.app"

  # Ebb is ad-hoc signed rather than notarized, so clear the download quarantine or
  # Gatekeeper refuses to open it.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Ebb.app"]
  end

  uninstall signal: [["TERM", "io.github.znlong2203.ebb"]]

  zap trash: [
    "~/Library/Preferences/io.github.znlong2203.ebb.plist",
    "~/Library/Saved Application State/io.github.znlong2203.ebb.savedState",
  ]
end
