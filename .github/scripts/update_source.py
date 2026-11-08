#!/usr/bin/env python3
"""Build the shared update manifest from the exact release IPA."""

import argparse
import datetime
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import zipfile


def release_version(value):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value) or len(value) > 40:
        raise ValueError("TwitchPlusK version must have three numeric components")
    return value


def stamp_build(app_path, version):
    release_version(version)
    app_path = Path(app_path)
    plists = [app_path / "Info.plist", *app_path.glob("PlugIns/*.appex/Info.plist")]
    for path in plists:
        original = path.read_bytes()
        info = plistlib.loads(original)
        info.setdefault("TPKOriginalTwitchVersion", info["CFBundleShortVersionString"])
        info.setdefault("TPKOriginalTwitchBuild", str(info["CFBundleVersion"]))
        info["CFBundleShortVersionString"] = version
        info["CFBundleVersion"] = version
        fmt = plistlib.FMT_BINARY if original.startswith(b"bplist") else plistlib.FMT_XML
        path.write_bytes(plistlib.dumps(info, fmt=fmt, sort_keys=False))


def ipa_metadata(ipa, ldid):
    entitlements, privacy = set(), {}
    with zipfile.ZipFile(ipa) as archive, tempfile.TemporaryDirectory() as temporary:
        roots = [n for n in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(roots) != 1:
            raise ValueError("Expected exactly one main app in Payload")
        root = roots[0].removesuffix("Info.plist")
        main = plistlib.loads(archive.read(roots[0]))
        if main["CFBundleIdentifier"] != "tv.twitch":
            raise ValueError("Expected Twitch bundle identifier tv.twitch")
        paths = [roots[0], *sorted(n for n in archive.namelist()
                                 if re.fullmatch(re.escape(root) + r"PlugIns/[^/]+\.appex/Info\.plist", n))]
        for index, path in enumerate(paths):
            info = plistlib.loads(archive.read(path))
            for key, value in info.items():
                if "UsageDescription" in key:
                    if not isinstance(value, str):
                        raise ValueError(f"Invalid privacy description: {key}")
                    privacy.setdefault(key, value)
            executable = info["CFBundleExecutable"]
            if "/" in executable or executable in (".", ".."):
                raise ValueError("Invalid bundle executable")
            binary = Path(temporary) / str(index)
            binary.write_bytes(archive.read(path.removesuffix("Info.plist") + executable))
            result = subprocess.run([ldid, "-e", str(binary)], check=True, capture_output=True)
            values = plistlib.loads(result.stdout) if result.stdout.strip() else {}
            if not isinstance(values, dict):
                raise ValueError("Invalid executable entitlements")
            entitlements.update(values)
    entitlements.difference_update({"application-identifier", "com.apple.developer.team-identifier"})
    return main, {"entitlements": sorted(entitlements), "privacy": dict(sorted(privacy.items()))}


def make_source(ipa, version, date, repository, ldid):
    release_version(version)
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repository):
        raise ValueError("Invalid GitHub repository")
    datetime.datetime.fromisoformat(date.replace("Z", "+00:00"))
    info, permissions = ipa_metadata(ipa, ldid)
    twitch = info["TPKOriginalTwitchVersion"]
    if info["CFBundleShortVersionString"] != version or str(info["CFBundleVersion"]) != version:
        raise ValueError("IPA version and build must match the TwitchPlusK release version")
    expected_name = f"tpK-{version}-Twitch-{twitch}.ipa"
    if Path(ipa).name != expected_name:
        raise ValueError(f"Expected IPA filename {expected_name}")
    tag = f"twitchplusk-v{version}-twitch-{twitch}"
    base = f"https://github.com/{repository}"
    raw = f"https://raw.githubusercontent.com/{repository}/main"
    icon = raw + "/Assets/twitchplusk-icon.webp"
    app_version = {
        "version": info["CFBundleShortVersionString"],
        "buildVersion": str(info["CFBundleVersion"]),
        "marketingVersion": f"{version} (Twitch {twitch})",
        "date": date,
        "downloadURL": f"{base}/releases/download/{tag}/{expected_name}",
        "size": Path(ipa).stat().st_size,
        "minOSVersion": info["MinimumOSVersion"],
    }
    return {
        "version": version,
        "name": "TwitchPlusK",
        "identifier": "com." + repository.split('/')[0].lower() + ".twitchplusk.source",
        "sourceURL": raw + "/update.json",
        "website": base,
        "iconURL": icon,
        "tintColor": "9146FF",
        "apps": [{
            "name": "TwitchPlusK",
            "bundleIdentifier": info["CFBundleIdentifier"],
            "developerName": repository.split('/')[0],
            "localizedDescription": "Twitch for iOS with customizable chat, extra emotes, ad blocking and more. Full changelog: " + base + "/blob/main/CHANGELOG.md",
            "iconURL": icon,
            "versions": [app_version],
            "version": app_version["version"],
            "versionDate": date,
            "downloadURL": app_version["downloadURL"],
            "size": app_version["size"],
            "appPermissions": permissions,
        }],
        "news": [],
    }


def write_source(source, output):
    data = (json.dumps(source, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    if len(data) > 16384:
        raise ValueError("Source exceeds the existing tweak updater's 16 KiB limit")
    output = Path(output)
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_bytes(data)
    temporary.replace(output)
    print(f"Validated {output}: {len(data)} bytes")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    stamp = commands.add_parser("stamp-build")
    stamp.add_argument("app")
    stamp.add_argument("version")
    build = commands.add_parser("generate")
    build.add_argument("ipa")
    build.add_argument("version")
    build.add_argument("date")
    build.add_argument("--repository", default="Knoks1111/TwitchPlusK")
    build.add_argument("--ldid", default="ldid")
    build.add_argument("--output", default="update.json")
    args = parser.parse_args()
    if args.command == "stamp-build":
        stamp_build(args.app, args.version)
    else:
        write_source(make_source(args.ipa, args.version, args.date, args.repository, args.ldid), args.output)


if __name__ == "__main__":
    main()
