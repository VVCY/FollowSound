#!/usr/bin/env python3
"""建 Release 并上传 dist/ 下的产物。

github.com:443 在本机不通，所以只走 api / uploads 两个域名，HTTP 用 curl 发。

    GH_TOKEN=xxx ./scripts/release-upload.py                 # 版本号取自 macos/VERSION
    GH_TOKEN=xxx ./scripts/release-upload.py --version 1.0.5
    GH_TOKEN=xxx ./scripts/release-upload.py --dry-run       # 只打印会传什么

缺哪个平台的包就跳过哪个（比如 Windows 没在这台机器上构建出来）。
重跑安全：Release 已存在时复用，同名资产先删再传。
"""
import json
import os
import subprocess
import sys

REPO = "VVCY/FollowSound"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(ROOT, "dist")
TOKEN = os.environ.get("GH_TOKEN", "")


def assets(version):
    """(dist 内相对路径, MIME)。带版本号的正式名 + 固定别名各传一份。

    固定别名是官网写死的 latest/download/xxx，升版本时网页一个字都不用改。
    """
    return [
        (f"macos/FollowSound-macOS-{version}.zip", "application/zip"),
        ("macos/FollowSound-macOS.zip", "application/zip"),
        (f"macos/FollowSound-macOS-{version}.dmg", "application/x-apple-diskimage"),
        (f"windows/FollowSound-Windows-{version}-Setup.exe", "application/octet-stream"),
        ("windows/FollowSound-Windows-Setup.exe", "application/octet-stream"),
        (f"windows/FollowSound-Windows-{version}-x64.zip", "application/zip"),
        ("windows/latest.yml", "text/yaml"),
        (f"android/FollowSound-Android-{version}.apk",
         "application/vnd.android.package-archive"),
        ("android/FollowSound-Android.apk", "application/vnd.android.package-archive"),
        ("SHA256SUMS.txt", "text/plain"),
    ]


def curl_json(args):
    out = subprocess.check_output(["curl", "-4", "-sS", "--max-time", "120",
                                   "-H", "Authorization: Bearer " + TOKEN,
                                   "-H", "Accept: application/vnd.github+json",
                                   "-H", "User-Agent: FollowSound-release", *args])
    return json.loads(out.decode() or "{}")


def main(argv):
    version = None
    dry = "--dry-run" in argv
    if "--version" in argv:
        version = argv[argv.index("--version") + 1]
    if not version:
        version = open(os.path.join(ROOT, "macos", "VERSION"), encoding="utf-8").read().strip()
    tag = "v" + version

    # release-notes.md 只取最上面那一段；段落之间是「空行 + --- + 空行」，
    # 不能直接 split("---")，否则会切在 markdown 表格的 | --- | 中间。
    notes = open(os.path.join(ROOT, "docs", "release-notes.md"), encoding="utf-8").read()
    notes = notes.split("\n---\n")[0].strip()

    all_assets = assets(version)
    todo = [(p, t) for p, t in all_assets if os.path.exists(os.path.join(DIST, p))]
    missing = [p for p, _ in all_assets if not os.path.exists(os.path.join(DIST, p))]

    print(f"版本 {version}  标签 {tag}")
    if missing:
        print("跳过（本地没有）:", ", ".join(missing))
    for p, _ in todo:
        print(f"  上传 {p}  ({os.path.getsize(os.path.join(DIST, p)) // 1024} KB)")
    if dry:
        print("\n--- release body ---")
        print(notes)
        return 0
    if not TOKEN:
        print("缺少 GH_TOKEN", file=sys.stderr)
        return 1
    if not todo:
        print("dist/ 里没有可上传的产物", file=sys.stderr)
        return 1

    body = json.dumps({
        "tag_name": tag,
        "target_commitish": "main",
        "name": f"随响 FollowSound {tag}",
        "body": notes,
        "draft": False,
        "prerelease": False,
    })

    rel = curl_json([f"https://api.github.com/repos/{REPO}/releases/tags/{tag}"])
    if rel.get("id"):
        # 重跑时复用同一个 Release：先删掉同名资产再重传，避免 422
        print(f"Release {tag} 已存在（id={rel['id']}），复用")
        rid = rel["id"]
        for old in rel.get("assets", []):
            print("  删旧资产", old["name"], flush=True)
            curl_json(["-X", "DELETE",
                       f"https://api.github.com/repos/{REPO}/releases/assets/{old['id']}"])
        curl_json(["-X", "PATCH", "-H", "Content-Type: application/json",
                   "--data-binary", json.dumps({"body": notes,
                                                "name": f"随响 FollowSound {tag}"}),
                   f"https://api.github.com/repos/{REPO}/releases/{rid}"])
    else:
        rel = curl_json(["-X", "POST", "-H", "Content-Type: application/json",
                         "--data-binary", body,
                         f"https://api.github.com/repos/{REPO}/releases"])
        rid = rel.get("id")
        if not rid:
            print("建 Release 失败:", rel, file=sys.stderr)
            return 1
        print("release", rid, rel["html_url"])

    for rel_path, ctype in todo:
        path = os.path.join(DIST, rel_path)
        name = os.path.basename(path)
        print(f"upload {name} ({os.path.getsize(path) // 1024} KB)", flush=True)
        out = subprocess.check_output([
            "curl", "-4", "-sS", "--max-time", "1800", "-X", "POST",
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
    print("完成:", f"https://github.com/{REPO}/releases/tag/{tag}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
