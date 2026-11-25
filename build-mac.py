"""建立本機測試用 Mac 安裝包。產物預設僅使用 ad hoc 應用程式簽章。"""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from xml.etree import ElementTree as ET

HERE = Path(__file__).resolve().parent
APP = "AutoSidecar Companion"
IDENTIFIER = "org.autosidecar.companion"
VERSION = "0.2.0"


def run(*args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def plist(path, values):
    path.write_bytes(plistlib.dumps(values))


def sign(bundle, identity, entitlements=None):
    args = ["/usr/bin/codesign", "--force", "--sign", identity, "--options", "runtime"]
    args.append("--timestamp=none" if identity == "-" else "--timestamp")
    if entitlements:
        args += ["--entitlements", entitlements]
    run(*args, bundle)
    run("/usr/bin/codesign", "--verify", "--strict", bundle)


def build_payload(temp, source, architectures, identity):
    app = temp / "host" / (APP + ".app")
    macos, resources = app / "Contents/MacOS", app / "Contents/Resources"
    macos.mkdir(parents=True)
    resources.mkdir()
    binaries, drivers = [], []
    # Reuse the upstream factory UUID and device UIDs for existing audio setups.
    driver_dir = temp / "audio"
    run("bash", source / "scripts/build-audio-driver.sh",
        env={**os.environ, "SIGN_IDENTITY": "-", "OUT": str(driver_dir)})
    driver = driver_dir / "WiredDisplayAudio.driver"
    driver_binary = driver / "Contents/MacOS/WiredDisplayAudio"
    for arch in architectures:
        build = ["xcrun", "swift", "build", "--package-path", source, "-c", "release",
                 "--triple", f"{arch}-apple-macosx14.0", "--scratch-path", temp / arch]
        run(*build, "--product", "WiredDisplayHost", "-j", "4")
        binary_dir = run(*build, "--show-bin-path", capture_output=True, text=True).stdout.strip()
        binaries.append(Path(binary_dir) / "WiredDisplayHost")
        dest = temp / f"audio-{arch}"
        run("xcrun", "clang", "-std=c11", "-O2", "-arch", arch, "-mmacosx-version-min=14.0",
            "-bundle", "-o", dest, source / "MacVirtualDevices/AudioDriver/WiredDisplayAudio.c",
            "-framework", "CoreAudio", "-framework", "CoreFoundation")
        drivers.append(dest)
    exe = macos / "AutoSidecarCompanion"
    for slices, target in ((binaries, exe), (drivers, driver_binary)):
        run("xcrun", "lipo", "-create", *slices, "-output", target)
        run("xcrun", "strip", "-S", target)
        found = run("xcrun", "lipo", "-archs", target, capture_output=True, text=True).stdout.split()
        if sorted(found) != sorted(architectures):
            raise RuntimeError(f"{target.name}: 預期架構 {architectures}，實際為 {found}")
    shutil.copyfile(source / "macOSHost/Resources/AppIcon.icns", resources / "AppIcon.icns")
    shutil.copyfile(source / "LICENSE", resources / "WiredDisplay-LICENSE.txt")
    (resources / "Credits.txt").write_text(
        "AutoSidecar Companion incorporates WiredDisplay.\nhttps://github.com/sibawono/WiredDisplay\n"
        "The bundled source license is GNU GPL version 3.\n")
    app_info = {
        "CFBundleIdentifier": IDENTIFIER + ".host", "CFBundleName": APP,
        "CFBundleDisplayName": APP, "CFBundleExecutable": exe.name,
        "CFBundlePackageType": "APPL", "CFBundleIconFile": "AppIcon.icns",
        "CFBundleShortVersionString": VERSION, "CFBundleVersion": "2",
        "LSMinimumSystemVersion": "14.0", "LSUIElement": True, "NSHighResolutionCapable": True,
        "NSMicrophoneUsageDescription": "讀取「iPad Speaker」虛擬音訊裝置，將 Mac 聲音傳到已配對的 iPad。"
    }
    receiver_url = os.environ.get("AUTOSIDECAR_RECEIVER_URL")
    if receiver_url:
        app_info["AutoSidecarReceiverURL"] = receiver_url
    plist(app / "Contents/Info.plist", app_info)
    entitlements = temp / "audio.entitlements"
    plist(entitlements, {"com.apple.security.device.audio-input": True})
    sign(app, identity, entitlements)
    driver_resources = driver / "Contents/Resources"
    driver_resources.mkdir(exist_ok=True)
    shutil.copyfile(source / "LICENSE", driver_resources / "WiredDisplay-LICENSE.txt")
    sign(driver, identity)
    return app, driver


def component(temp, payload, location, identifier, scripts=None):
    description = temp / (identifier + ".plist")
    run("pkgbuild", "--analyze", "--root", payload.parent, description)
    info = plistlib.loads(description.read_bytes())
    for item in info:
        item["BundleIsRelocatable"] = False
    plist(description, info)
    output = temp / (identifier + ".pkg")
    script_args = ["--scripts", scripts] if scripts else []
    run("pkgbuild", "--root", payload.parent, "--component-plist", description,
        "--ownership", "recommended", "--install-location", location,
        "--identifier", IDENTIFIER + "." + identifier, "--version", VERSION, *script_args, output)
    return output


def product(temp, app, driver, architectures, destination, installer):
    scripts = temp / "launch"
    scripts.mkdir()
    post = scripts / "postinstall"
    post.write_text("""#!/bin/sh
# 只在安裝至目前啟動磁碟、且已有使用者登入圖形介面時開啟 App。
[ "$3" = "/" ] || exit 0
uid=$(/usr/bin/stat -f %u /dev/console)
[ "$uid" -ge 501 ] 2>/dev/null || exit 0
/bin/launchctl asuser "$uid" /usr/bin/sudo -n -u "#$uid" /usr/bin/open -g "/Applications/AutoSidecar Companion.app" || :
exit 0
""")
    post.chmod(0o755)
    packages = {"audio": component(temp, driver, "/Library/Audio/Plug-Ins/HAL", "audio"),
                "desktop": component(temp, app, "/Applications", "desktop", scripts)}
    doc = ET.Element("installer-gui-script", {"minSpecVersion": "2"})
    ET.SubElement(doc, "title").text = "AutoSidecar Companion"
    ET.SubElement(doc, "options", {"customize": "never", "require-scripts": "true",
                                  "hostArchitectures": ",".join(architectures)})
    ET.SubElement(doc, "domains", {"enable_anywhere": "false", "enable_currentUserHome": "false",
                                  "enable_localSystem": "true"})
    requirement = ET.SubElement(doc, "volume-check")
    ET.SubElement(ET.SubElement(requirement, "allowed-os-versions"), "os-version", {"min": "14.0"})
    outline = ET.SubElement(doc, "choices-outline")
    for name, pkg in packages.items():
        ET.SubElement(outline, "line", {"choice": name})
        options = {"id": name, "visible": "false", "title": name}
        if name == "audio":  # A compatible shared driver may already be owned by another install.
            options["selected"] = "!system.files.fileExistsAtPath('/Library/Audio/Plug-Ins/HAL/WiredDisplayAudio.driver')"
        choice = ET.SubElement(doc, "choice", options)
        pid = IDENTIFIER + "." + name
        ET.SubElement(choice, "pkg-ref", {"id": pid})
        ET.SubElement(doc, "pkg-ref", {"id": pid, "version": VERSION}).text = pkg.name
    definition = temp / "Distribution"
    ET.ElementTree(doc).write(definition, encoding="utf-8", xml_declaration=True)
    pending = temp / "AutoSidecar-Companion.pkg"
    sign_args = ["--sign", installer, "--timestamp"] if installer else []
    run("productbuild", "--distribution", definition, "--package-path", temp, *sign_args, pending)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(pending, destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--arch", choices=("arm64", "universal"), default="universal")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("輸出路徑已存在，請指定新的測試包檔名")
    architectures = ["arm64", "x86_64"] if args.arch == "universal" else ["arm64"]
    with tempfile.TemporaryDirectory(prefix="autosidecar-build-") as scratch:
        temp = Path(scratch)
        source = HERE
        app, driver = build_payload(temp, source, architectures, os.environ.get("APP_SIGN_IDENTITY", "-"))
        product(temp, app, driver, architectures, args.output, os.environ.get("INSTALLER_SIGN_IDENTITY"))


if __name__ == "__main__":
    main()
