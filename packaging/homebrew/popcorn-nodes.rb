cask "popcorn-nodes" do
  version "1.0.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/team-datapopcorn/popcorn-nodes/releases/download/v#{version}/PopcornNodes-#{version}.dmg"
  name "Popcorn Nodes"
  desc "Menu bar dashboard for your Macs, Windows PCs and Linux boxes over SSH"
  homepage "https://github.com/team-datapopcorn/popcorn-nodes"

  depends_on macos: ">= :sonoma"

  app "Popcorn Nodes.app"

  zap trash: "~/Library/Application Support/PopcornNodes"
end
