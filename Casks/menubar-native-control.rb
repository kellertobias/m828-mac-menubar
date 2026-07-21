cask "menubar-native-control" do
  version :latest
  sha256 :no_check

  url "https://github.com/kellertobias/m828-mac-menubar/releases/latest/download/Menubar-Native-Control-macos-universal.tar.gz"
  name "Menubar Native Control"
  name "M828 Mac Menu Bar"
  desc "Menu bar controller for MOTU 828ES and other AVB mixers"
  homepage "https://github.com/kellertobias/m828-mac-menubar"

  depends_on macos: :ventura

  app "Menubar Native Control.app"

  # The app is a universal build, ad-hoc signed but not notarized (there is no
  # Apple Developer account). Homebrew quarantines the download, so Gatekeeper
  # would otherwise block first launch. Clear the quarantine and re-sign the
  # bundle locally so it launches without any prompt — no Apple ID involved.
  postflight do
    app_path = "#{appdir}/Menubar Native Control.app"
    system_command "/usr/bin/xattr", args: ["-cr", app_path]
    system_command "/usr/bin/codesign", args: ["--force", "--deep", "--sign", "-", app_path]
  end

  uninstall quit: "com.local.MenubarNativeControl"

  zap trash: "~/Library/Preferences/com.local.MenubarNativeControl.plist"
end
