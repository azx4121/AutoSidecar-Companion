"""以唯讀方式解包並檢查 Mac 測試包。唯有 --local-check 會執行其中的診斷。"""
import argparse
import json
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path
from xml.etree import ElementTree


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def check(pkg, local):
    with tempfile.TemporaryDirectory(prefix="autosidecar-check-") as temp:
        root = Path(temp) / "expanded"
        run("pkgutil", "--expand-full", pkg, root)
        distribution = ElementTree.parse(root / "Distribution")
        declared = set(distribution.find("options").get("hostArchitectures").split(","))
        for name, location, relative, identity in (
            ("desktop", "/Applications", "AutoSidecar Companion.app", "org.autosidecar.companion.host"),
            ("audio", "/Library/Audio/Plug-Ins/HAL", "WiredDisplayAudio.driver", "dev.wireddisplay.audio")
        ):
            component = root / (name + ".pkg")
            assert ElementTree.parse(component / "PackageInfo").getroot().get("install-location") == location
            bundle = component / "Payload" / relative
            metadata = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
            assert metadata["CFBundleIdentifier"] == identity
            run("codesign", "--verify", "--strict", bundle)
            executable = bundle / "Contents/MacOS" / metadata["CFBundleExecutable"]
            assert set(run("xcrun", "lipo", "-archs", executable).split()) == declared
            binary = executable.read_bytes()
            assert not re.search(rb"/Users/[a-zA-Z0-9._-]+/", binary)
            assert (bundle / "Contents/Resources/WiredDisplay-LICENSE.txt").is_file()
            print(f"{relative} 通過簽章完整性、識別與架構檢查")
            if name == "desktop" and local:
                probe = json.loads(run(executable, "--portable-check"))
                assert all(isinstance(value, bool) for value in probe.values())
                assert {"hasBuiltInScreen", "legacyControllerRunning", "speakerDriverReady"} <= probe.keys()
                print(json.dumps(probe, ensure_ascii=False, sort_keys=True))
        assert (root / "desktop.pkg/Scripts/postinstall").is_file()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--local-check", action="store_true")
    options = parser.parse_args()
    check(options.package, options.local_check)
