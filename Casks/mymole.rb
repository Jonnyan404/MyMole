cask "mymole" do
  version "1.0,57"
  sha256 "ab1f37ef2ef73c11383824afeb90c7c810c4e024377d7ce3dbdc59d29058971f"

  url "https://github.com/compilererrors/MyMole/releases/download/v1.0-build57/MyMole-1.0-macOS-arm64.zip"
  name "MyMole"
  desc "Disk usage analyzer, app uninstaller, and system activity monitor"
  homepage "https://github.com/compilererrors/MyMole"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "MyMole.app"
end
