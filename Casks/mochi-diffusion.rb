cask "mochi-diffusion" do
  version "3.0"
  url "https://github.com/godly-devotion/MochiDiffusion/releases/download/v#{version}/MochiDiffusion_v#{version}.dmg"
  sha256 "0d91f07fdfb8780cbeae01cc439b2dc613e2dc3062699ffa38b504bd541d7d67"

  name "MochiDiffusion"
  desc "Run Stable Diffusion on Mac natively"
  homepage "https://github.com/godly-devotion/MochiDiffusion"

  app "Mochi Diffusion.app"

  uninstall quit: "com.joshua-park.Mochi-Diffusion"
end