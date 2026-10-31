#!/usr/bin/env python3
"""github.com:443 在本机不通（api.github.com 通），所以用 Git Data API 把本地提交搬上去：
blob → tree → commit → 更新 ref。HTTP 走 curl：本机 Python 直连会被拦，curl 正常。"""
import base64
import json
import os
import subprocess
import sys

REPO = "VVCY/FollowSound"
TOKEN = os.environ["GH_TOKEN"]
API = "https://api.github.com"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def curl(method, url, payload=None):
    cmd = ["curl", "-4", "-sS", "--max-time", "60", "-X", method,
           "-H", "Authorization: Bearer " + TOKEN,
           "-H", "Accept: application/vnd.github+json",
           "-H", "User-Agent: FollowSound-release"]
    if payload is not None:
        cmd += ["-H", "Content-Type: application/json", "--data-binary", json.dumps(payload)]
    cmd.append(url)
    out = subprocess.check_output(cmd)
    return json.loads(out.decode() or "{}")


def git(*args):
    return subprocess.check_output(["git", "-C", ROOT, *args]).decode().strip()


def main():
    local_head = git("rev-parse", "HEAD")
    parent = git("rev-parse", "HEAD^")
    message = git("log", "-1", "--pretty=%B")

    remote = curl("GET", f"{API}/repos/{REPO}/git/ref/heads/main")["object"]["sha"]
    if remote != parent:
        print(f"远端已不是 {parent[:7]}（现在 {remote[:7]}），先看清楚再推", file=sys.stderr)
        return 1

    entries = []
    for path in git("diff", "--name-only", parent, local_head).splitlines():
        blob = subprocess.check_output(["git", "-C", ROOT, "show", f"{local_head}:{path}"])
        sha = curl("POST", f"{API}/repos/{REPO}/git/blobs",
                   {"content": base64.b64encode(blob).decode(), "encoding": "base64"})["sha"]
        entries.append({"path": path, "mode": "100644", "type": "blob", "sha": sha})
        print("blob", path, sha[:8])

    base_tree = curl("GET", f"{API}/repos/{REPO}/git/commits/{parent}")["tree"]["sha"]
    tree = curl("POST", f"{API}/repos/{REPO}/git/trees", {"base_tree": base_tree, "tree": entries})["sha"]
    commit = curl("POST", f"{API}/repos/{REPO}/git/commits",
                  {"message": message, "tree": tree, "parents": [parent]})["sha"]
    curl("PATCH", f"{API}/repos/{REPO}/git/refs/heads/main", {"sha": commit, "force": False})
    print("commit", commit)
    return 0


if __name__ == "__main__":
    sys.exit(main())
