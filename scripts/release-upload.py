#!/usr/bin/env python3
"""建 v1.0.1 Release 并上传产物。github.com 不通，只走 api / uploads 两个域名，HTTP 用 curl。"""
import json
import os
import subprocess
import sys

REPO = "VVCY/FollowSound"
TAG = "v1.0.1"
TOKEN = os.environ["GH_TOKEN"]
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(ROOT, "dist")

ASSETS = [
    ("macos/FollowSound-macOS-1.0.1.zip", "application/zip"),
    ("macos/FollowSound-macOS.zip", "application/zip"),
    ("macos/FollowSound-macOS-1.0.1.dmg", "application/x-apple-diskimage"),
    ("windows/FollowSound-Windows-1.0.1-Setup.exe", "application/octet-stream"),
    ("windows/FollowSound-Windows-Setup.exe", "application/octet-stream"),
    ("windows/FollowSound-Windows-1.0.1-x64.zip", "application/zip"),
    ("windows/latest.yml", "text/yaml"),
    ("android/FollowSound-Android-1.0.1.apk", "application/vnd.android.package-archive"),
    ("android/FollowSound-Android.apk", "application/vnd.android.package-archive"),
    ("SHA256SUMS.txt", "text/plain"),
]


def curl_json(args):
    out = subprocess.check_output(["curl", "-4", "-sS", "--max-time", "120",
                                   "-H", "Authorization: Bearer " + TOKEN,
                                   "-H", "Accept: application/vnd.github+json",
                                   "-H", "User-Agent: FollowSound-release", *args])
    return json.loads(out.decode() or "{}")


def main():
    notes = open(os.path.join(ROOT, "docs", "release-notes.md"), encoding="utf-8").read()
    notes = notes.split("---")[0].strip()   # 只取 1.0.1 那一段

    body = json.dumps({
        "tag_name": TAG,
        "target_commitish": "main",
        "name": "随响 FollowSound v1.0.1",
        "body": notes,
        "draft": False,
        "prerelease": False,
    })
    rel = curl_json(["-X", "POST", "-H", "Content-Type: application/json",
                     "--data-binary", body,
                     f"https://api.github.com/repos/{REPO}/releases"])
    rid = rel.get("id")
    if not rid:
        print("建 Release 失败:", rel, file=sys.stderr)
        return 1
    print("release", rid, rel["html_url"])

    for rel_path, ctype in ASSETS:
        path = os.path.join(DIST, rel_path)
        name = os.path.basename(path)
        print(f"upload {name} ({os.path.getsize(path) // 1024} KB)", flush=True)
        out = subprocess.check_output([
            "curl", "-4", "-sS", "--max-time", "900", "-X", "POST",
            "-H", "Authorization: Bearer " + TOKEN,
            "-H", "Content-Type: " + ctype,
            "-H", "User-Agent: FollowSound-release",
            "--data-binary", "@" + path,
            f"https://uploads.github.com/repos/{REPO}/releases/{rid}/assets?name={name}",
        ])
        res = json.loads(out.decode() or "{}")
        if res.get("state") != "uploaded":
            print("  失败:", res, file=sys.stderr)
            return 1
        print("  ok", res["size"], res["browser_download_url"], flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
