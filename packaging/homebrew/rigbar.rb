cask "rigbar" do
  version "1.0.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/team-datapopcorn/rigbar/releases/download/v#{version}/Rigbar-#{version}.dmg"
  name "Rigbar"
  desc "Menu bar dashboard for your Macs, Windows PCs and Linux boxes over SSH"
  homepage "https://github.com/team-datapopcorn/rigbar"

  depends_on macos: ">= :sonoma"

  app "Rigbar.app"

  zap trash: "~/Library/Application Support/Rigbar"
end
