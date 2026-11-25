#!/usr/bin/env python3
"""Renew an existing iPad development build through Xcode and CoreDevice."""
import argparse
from datetime import datetime, timedelta, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "iPadOSClient/WiredDisplayClient/WiredDisplayClient.xcodeproj"
SUPPORT = Path.home() / "Library/Application Support/AutoSidecar Receiver Renewal"
LABEL = "org.autosidecar.companion.receiver-renewal"
AGENT = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
DOMAIN = f"gui/{os.getuid()}"
SCHEME = "WiredDisplayClient"
XCRUN = "/usr/bin/xcrun"


class RenewalError(Exception):
    pass


class RetryUSB(RenewalError):
    pass


def run(*args, timeout=30, check=True):
    return subprocess.run(args, capture_output=True, check=check, timeout=timeout)


def device_call(*args, timeout=12):
    with tempfile.TemporaryDirectory(prefix="autosidecar-device-") as scratch:
        file = Path(scratch) / "result.json"
        run(XCRUN, "devicectl", *args, "--timeout", str(timeout), "--json-output", str(file),
            timeout=timeout + 5)
        return json.loads(file.read_bytes())["result"]


def usb_ipads():
    def collect(nodes):
        for entry in nodes:
            if (entry.get("idVendor") == 1452 and entry.get("USB Product Name", "").startswith("iPad")
                    and "IORegistryEntryID" in entry):
                yield entry["IORegistryEntryID"]
            yield from collect(entry.get("IORegistryEntryChildren", ()))

    result = run("/usr/sbin/ioreg", "-a", "-p", "IOUSB", "-r", "-c", "IOUSBHostDevice")
    return set(collect(plistlib.loads(result.stdout)))


def target_ipad():
    result = device_call("list", "devices")
    devices = [d for d in result["devices"]
               if d["hardwareProperties"].get("deviceType") == "iPad"
               and d["connectionProperties"].get("transportType") == "wired"
               and d["connectionProperties"].get("pairingState") == "paired"]
    if len(devices) != 1:
        raise RetryUSB("請只用 USB-C 接上一部已與這台 Mac 配對的 iPad，並解鎖。")
    device = devices[0]
    if device["deviceProperties"].get("developerModeStatus") != "enabled":
        raise RenewalError("請先在 iPad 啟用開發者模式，並在 Xcode 完成首次安裝。")
    try:
        unlocked = not device_call("device", "info", "lockState", "--device", device["identifier"])["passcodeRequired"]
    except subprocess.CalledProcessError:
        raise RetryUSB("等待 iPad 回應。請保持 iPad 解鎖。") from None
    if not unlocked:
        raise RetryUSB("請解鎖 iPad，續簽工具會在這次接線期間再試。")
    return device["identifier"], device["hardwareProperties"]["udid"]


def installed_app(device, bundle):
    apps = device_call("device", "info", "apps", "--device", device)["apps"]
    app = next((app for app in apps if app["bundleIdentifier"] == bundle), None)
    if not app or not app.get("builtByDeveloper"):
        raise RenewalError("iPad 找不到這個開發版接收器。請先在 Xcode 安裝一次，並使用同一個 App 識別碼。")
    return app


def signed_entitlements(app):
    return plistlib.loads(run("/usr/bin/codesign", "--display", "--entitlements", ":-", str(app)).stdout)


def decode_profile(path):
    return plistlib.loads(run("/usr/bin/security", "cms", "-D", "-i", str(path)).stdout)


def profile_expiry(profile):
    return profile["ExpirationDate"].replace(tzinfo=timezone.utc)


def matching_teams(bundle, udid):
    homes = ("Library/Developer/Xcode/UserData/Provisioning Profiles",
             "Library/MobileDevice/Provisioning Profiles")
    teams = set()
    for home in homes:
        for file in (Path.home() / home).glob("*.mobileprovision"):
            try:
                profile = decode_profile(file)
                app_id = profile.get("Entitlements", {}).get("application-identifier", "")
                team, _, product = app_id.partition(".")
                if product == bundle and udid.casefold() in {u.casefold() for u in profile.get("ProvisionedDevices", ())}:
                    teams.add(team)
            except (subprocess.CalledProcessError, ValueError):
                continue
    return teams


def xcode_args(project):
    return [XCRUN, "xcodebuild", "-project", str(project), "-scheme", SCHEME,
            "-configuration", "Release", "-destination", "generic/platform=iOS"]


def profile_matches(profile, team, bundle, udid):
    entitlements = profile.get("Entitlements", {})
    return (entitlements.get("application-identifier") == f"{team}.{bundle}" and entitlements.get("get-task-allow")
            and udid.casefold() in {item.casefold() for item in profile.get("ProvisionedDevices", ())})


def receiver_settings(args, udid):
    reference = None
    version_overrides = []
    if args.reference_app:
        meta = plistlib.loads((args.reference_app / "Info.plist").read_bytes())
        reference = decode_profile(args.reference_app / "embedded.mobileprovision")
        bundle = meta["CFBundleIdentifier"]
        team = reference["TeamIdentifier"][0]
        version_overrides = [f"CURRENT_PROJECT_VERSION={meta['CFBundleVersion']}",
                             f"MARKETING_VERSION={meta['CFBundleShortVersionString']}",
                             f"INFOPLIST_KEY_CFBundleDisplayName={meta['CFBundleDisplayName']}"]
        if not profile_matches(reference, team, bundle, udid):
            raise RenewalError("指定的原始接收器與這部 iPad 或簽署團隊不符。")
    else:
        output = run(*xcode_args(args.project), "-showBuildSettings", "-json", timeout=60).stdout
        settings = next(entry["buildSettings"] for entry in json.loads(output) if entry["target"] == SCHEME)
        bundle = settings["PRODUCT_BUNDLE_IDENTIFIER"]
        team = settings.get("DEVELOPMENT_TEAM", "")
        if not team:
            teams = matching_teams(bundle, udid)
            if len(teams) != 1:
                raise RenewalError("請在 Xcode 選擇原本的開發團隊，並用相同的 App 識別碼完成首次安裝。")
            team = teams.pop()
    if not re.fullmatch(r"[A-Z0-9]{10}", team) or not re.fullmatch(r"[A-Za-z0-9.-]+", bundle):
        raise RenewalError("Xcode 專案的 App 識別碼或團隊設定有誤。")
    return bundle, team, version_overrides, reference


def known_expiry(state, installed, args, reference):
    try:
        recorded = json.loads(state.read_bytes())
        if recorded["build"] == installed["bundleVersion"] and recorded["version"] == installed["version"]:
            return datetime.fromisoformat(recorded["expiry"])
    except (FileNotFoundError, ValueError, KeyError):
        pass
    if reference:
        meta = plistlib.loads((args.reference_app / "Info.plist").read_bytes())
        if installed["bundleVersion"] == meta["CFBundleVersion"] and installed["version"] == meta["CFBundleShortVersionString"]:
            return profile_expiry(reference)
    return None


def show_expiry(expiry):
    return expiry.astimezone().strftime("%Y-%m-%d %H:%M %Z") if expiry else "待首次成功續簽確認"


def renew(args, automatic=False):
    with (SUPPORT / "renew.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RenewalError("已有續簽作業，請等候完成。") from None
        device, udid = target_ipad()
        bundle, team, overrides, reference = receiver_settings(args, udid)
        app = installed_app(device, bundle)
        key = hashlib.sha256(f"{udid}:{team}:{bundle}".encode()).hexdigest()
        state = SUPPORT / (key + ".json")
        previous = known_expiry(state, app, args, reference)
        print("目前簽署到期時間：" + show_expiry(previous), flush=True)
        now = datetime.now(timezone.utc)
        if args.check:
            print("已確認 iPad、原有接收器及簽署身分。", flush=True)
            return
        if automatic and previous and previous - now > timedelta(hours=24):
            print("簽署仍有效，這次接線直接使用既有接收器。", flush=True)
            return

        with tempfile.TemporaryDirectory(prefix="autosidecar-renew-") as build:
            print("Xcode 正在簽署原有接收器…", flush=True)
            result = run(*xcode_args(args.project), "-derivedDataPath", build, "-jobs", "2",
                         "-allowProvisioningUpdates", f"DEVELOPMENT_TEAM={team}",
                         f"PRODUCT_BUNDLE_IDENTIFIER={bundle}", *overrides, "build", timeout=300, check=False)
            if result.returncode:
                log = SUPPORT / "xcode.log"
                log.write_bytes(result.stdout + result.stderr)
                raise RenewalError(f"Xcode 簽署失敗。請確認帳號與開發團隊，詳細記錄在 {log}。")
            signed = Path(build) / "Build/Products/Release-iphoneos/WiredDisplayClient.app"
            run("/usr/bin/codesign", "--verify", "--strict", str(signed))
            profile = decode_profile(signed / "embedded.mobileprovision")
            expiry = profile_expiry(profile)
            meta = plistlib.loads((signed / "Info.plist").read_bytes())
            entitlements = signed_entitlements(signed)
            if (not profile_matches(profile, team, bundle, udid)
                    or meta.get("CFBundleIdentifier") != bundle or expiry <= datetime.now(timezone.utc)
                    or entitlements.get("application-identifier") != f"{team}.{bundle}"
                    or not entitlements.get("get-task-allow")):
                raise RenewalError("Xcode 產物的簽署身分、iPad 裝置或有效期限不符。")
            if args.reference_app:
                original = signed_entitlements(args.reference_app)
                if set(entitlements.get("keychain-access-groups", ())) != set(original.get("keychain-access-groups", ())):
                    raise RenewalError("新簽署的鑰匙圈權限與原有接收器不符，已保留原安裝。")
            if (app["bundleVersion"] != meta["CFBundleVersion"] or app["version"] != meta["CFBundleShortVersionString"]):
                raise RenewalError("來源版本與 iPad 上的版本不同。請使用相同版本的原始碼，或先經 Xcode 更新。")
            print("Xcode 產物到期時間：" + show_expiry(expiry), flush=True)
            if args.build_check:
                print("已驗證建置、簽章與描述檔。實機接收器維持原版。", flush=True)
                return
            if previous and expiry <= previous and (automatic or not args.reinstall):
                print("Apple 仍提供原有到期日，這次保留既有安裝。到期後接線會再次嘗試。", flush=True)
                return

            installed_app(device, bundle)
            device_call("device", "install", "app", "--device", device, str(signed), timeout=120)
            confirmed = installed_app(device, bundle)
            if confirmed["bundleVersion"] != meta["CFBundleVersion"] or confirmed["version"] != meta["CFBundleShortVersionString"]:
                raise RenewalError("iPad 回報的版本與安裝產物不符，請檢查接收器。")
            pending = state.with_suffix(".new")
            pending.write_text(json.dumps({"build": confirmed["bundleVersion"], "version": confirmed["version"],
                                           "expiry": expiry.isoformat()}))
            os.replace(pending, state)
            print("已覆蓋安裝接收器。簽署到期時間：" + show_expiry(expiry), flush=True)
            if args.launch_url:
                try:
                    device_call("device", "process", "launch", "--device", device,
                                "--payload-url", args.launch_url, bundle)
                except subprocess.CalledProcessError:
                    print("請在 iPad 主畫面開啟接收器。", flush=True)


def watch(args):
    attached = usb_ipads()
    print("正在等待下一次 USB-C 插線。", flush=True)
    pending = set()
    while True:
        time.sleep(2)
        try:
            current = usb_ipads()
        except (OSError, subprocess.SubprocessError, ValueError):
            continue
        pending = (pending & current) | (current - attached)
        attached = current
        if not pending or len(current) != 1:
            continue
        try:
            renew(args, automatic=True)
        except RetryUSB:
            time.sleep(5)
            continue
        except (RenewalError, subprocess.SubprocessError, OSError) as error:
            print(error if isinstance(error, RenewalError) else "續簽暫未完成，請確認 iPad 解鎖後重新插線。", flush=True)
        pending.clear()


def enable_agent(args):
    if AGENT.exists():
        raise RenewalError("USB 自動續簽已設定。要更換接收器時，請先用 --disable-auto 停用。")
    argv = [sys.executable, str(Path(__file__).resolve()), "--watch", "--project", str(args.project)]
    if args.reference_app:
        argv += ["--reference-app", str(args.reference_app)]
    if args.launch_url:
        argv += ["--launch-url", args.launch_url]
    AGENT.parent.mkdir(parents=True, exist_ok=True)
    log = str(SUPPORT / "usb.log")
    spec = {"Label": LABEL, "RunAtLoad": True, "ProcessType": "Background",
            "ProgramArguments": argv, "EnvironmentVariables": {"DEVELOPER_DIR": os.environ["DEVELOPER_DIR"]},
            "StandardOutPath": log, "StandardErrorPath": log}
    with AGENT.open("xb") as file:
        plistlib.dump(spec, file)
    try:
        run("/bin/launchctl", "bootstrap", DOMAIN, str(AGENT))
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        AGENT.unlink()
        raise
    print("已啟用 USB 自動續簽，下一次插線開始檢查。")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=PROJECT)
    parser.add_argument("--reference-app", type=Path, help="Use the identity and version of this existing signed build.")
    parser.add_argument("--launch-url", help="Open the existing receiver using this URL after a successful reinstall.")
    parser.add_argument("--reinstall", action="store_true", help="Reinstall even if Xcode returns the same expiry.")
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--check", action="store_true")
    action.add_argument("--build-check", action="store_true")
    action.add_argument("--watch", action="store_true")
    action.add_argument("--enable-auto", action="store_true")
    action.add_argument("--disable-auto", action="store_true")
    args = parser.parse_args()
    if args.disable_auto:
        if AGENT.exists():
            run("/bin/launchctl", "bootout", f"{DOMAIN}/{LABEL}", check=False)
            AGENT.unlink()
        print("已停用 USB 自動續簽。")
        return
    if "DEVELOPER_DIR" not in os.environ:
        selected = Path(run("/usr/bin/xcode-select", "-p").stdout.decode().strip())
        os.environ["DEVELOPER_DIR"] = str(selected if (selected / "usr/bin/xcodebuild").exists()
                                          else Path("/Applications/Xcode.app/Contents/Developer"))
    if not (Path(os.environ["DEVELOPER_DIR"]) / "usr/bin/xcodebuild").exists():
        raise RenewalError("請先安裝並開啟完整的 Xcode。")
    args.project = args.project.resolve(strict=True)
    if args.reference_app:
        args.reference_app = args.reference_app.resolve(strict=True)
    SUPPORT.mkdir(mode=0o700, parents=True, exist_ok=True)
    if args.enable_auto:
        enable_agent(args)
    elif args.watch:
        watch(args)
    else:
        renew(args)


if __name__ == "__main__":
    try:
        main()
    except RenewalError as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, StopIteration):
        print("續簽作業未完成。請確認 Xcode 已登入、iPad 已配對且保持解鎖。", file=sys.stderr)
        sys.exit(1)
