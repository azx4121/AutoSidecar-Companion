"""檢查可攜 IPA 的裝置、簽署狀態、識別與入口。"""
import plistlib
import sys
from pathlib import Path
from zipfile import ZipFile


def verify(path):
    with ZipFile(path) as archive:
        members = archive.namelist()
        apps = [name for name in members if name.endswith(".app/Info.plist")]
        if len(apps) != 1:
            raise ValueError("IPA 須含一個接收器 App")
        info = plistlib.loads(archive.read(apps[0]))
        if (info["CFBundleIdentifier"] != "org.autosidecar.companion.receiver"
                or info["UIDeviceFamily"] != [2]
                or info["CFBundleSupportedPlatforms"] != ["iPhoneOS"]):
            raise ValueError("App 識別或裝置平台錯誤")
        schemes = [scheme for role in info.get("CFBundleURLTypes", [])
                   for scheme in role.get("CFBundleURLSchemes", [])]
        if schemes != ["autosidecar-companion"]:
            raise ValueError("捷徑入口與既有接收器衝突")
        if any("_CodeSignature/" in name or name.endswith((".mobileprovision", ".p12", ".pem", ".log"))
               for name in members):
            raise ValueError("IPA 含簽署資料或日誌")
        app_dir = apps[0].removesuffix("Info.plist")
        executable = archive.read(app_dir + info["CFBundleExecutable"])
        if any(marker in executable for marker in (b"wireddisplay://smooth-usb",
                                                    b"autoSidecarManagedHighRefresh", b"/Users/")):
            raise ValueError("執行檔含個人建置路徑或舊模式入口")
        license_name = next((app_dir + name for name in ("LICENSE", "LICENSE.txt")
                             if app_dir + name in members), None)
        if not license_name or "GNU GENERAL PUBLIC LICENSE" not in archive.read(license_name).decode():
            raise ValueError("缺少上游授權")
        print("已驗證 iPadOS 裝置、獨立 App 識別、捷徑入口及未簽署封裝。")


if __name__ == "__main__":
    verify(Path(sys.argv[1]))
