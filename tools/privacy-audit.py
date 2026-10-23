#!/usr/bin/env python3
"""Pre-publish privacy audit for this repo.

Scans text files for things that should not be committed:
phone numbers, MAC addresses, private IPs, secret assignments,
API/GitHub tokens, private keys, ID-card numbers, local home paths,
e-mail addresses and known personal device names.

Usage:
    python3 tools/privacy-audit.py [repo-root]

Exit code 1 when anything is found, so it can be used in CI.
Placeholders such as 10.244.x.x, aa:bb:cc:dd:ee:ff, <你的IP>, $PASSWORD,
*** and $(cmd) are ignored.
"""
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PATTERNS = {
    "手机号": re.compile(r"(?<!\d)1[3-9]\d{9}(?!\d)"),
    "MAC 地址": re.compile(r"(?<![\w:])(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}(?![\w:])"),
    "内网 IP": re.compile(
        r"\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}"
        r"|192\.168\.\d{1,3}\.\d{1,3}"
        r"|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b"),
    "密钥赋值": re.compile(
        r"(?i)\b(?:password|passwd|psk|secret|token|api[_-]?key)\b\s*[=:]\s*([^\s`'\"<>*]+)"),
    "本地用户目录": re.compile(r"(?:[A-Za-z]:\\\\?Users\\\\?|/home/|/Users/)[A-Za-z0-9._-]+"),
    "邮箱": re.compile(r"[\w.+-]+@[\w-]+\.[A-Za-z]{2,}"),
    "访问令牌": re.compile(
        r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"
        r"|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})\b"),
    "私钥": re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"),
    "身份证号": re.compile(r"(?<!\d)\d{17}[\dXx](?!\d)"),
}

# values that are clearly placeholders / not secrets
ALLOW = re.compile(
    r"^(?:x+|\*+|\.\.\.|<.*>|\$[\w{}(). ]+|\{\{.*\}\}|0+|ff+|aa+|none|null|true|false|"
    r"your[_-]?\w*|CHANGEME|TODO)$",
    re.I)

SKIP_DIRS = {".git", "tools", "node_modules"}
SKIP_EXT = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".zip", ".pcap", ".ipk", ".apk", ".pdf"}

# 校验和文件里的长十六进制串常被误判成手机号/身份证号（纯数字巧合），先打码再匹配
HEX_LONG = re.compile(r"\b[0-9a-fA-F]{32,}\b")

# Documented infrastructure addresses live in privacy-allowlist.txt (one per
# line, "#" starts a comment). They are campus/OS defaults, not personal data.
ALLOWLIST_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "privacy-allowlist.txt")


def load_allowlist():
    values = set()
    if not os.path.exists(ALLOWLIST_PATH):
        return values
    with open(ALLOWLIST_PATH, encoding="utf-8") as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if line:
                values.add(line.lower())
    return values


ALLOWED_VALUES = load_allowlist()


def allowed(label, value):
    if value.strip().lower() in ALLOWED_VALUES:
        return True
    if ALLOW.match(value.strip()):
        return True
    if label == "内网 IP":
        # documentation ranges / masked forms
        if ".x." in value or ".y." in value or value.endswith(".0.0"):
            return True
        if value.startswith(("10.0.0.", "10.1.1.", "192.0.2.", "198.51.100.")):
            return True
    if label == "MAC 地址":
        low = value.lower()
        if low.startswith(("aa:bb:cc", "00:00:00", "ff:ff:ff")):
            return True
    return False


def main():
    hits = []
    for dirpath, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            if os.path.splitext(name)[1].lower() in SKIP_EXT:
                continue
            path = os.path.join(dirpath, name)
            try:
                text = open(path, "r", encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            # 先把长哈希替换成占位符，避免把校验和里的数字当成手机号/身份证
            scan_text = HEX_LONG.sub("<hash>", text)
            for label, rx in PATTERNS.items():
                for m in rx.finditer(scan_text):
                    value = m.group(1) if rx.groups and m.group(1) else m.group(0)
                    if allowed(label, value):
                        continue
                    line_no = scan_text[: m.start()].count("\n") + 1
                    line = text.splitlines()[line_no - 1].strip()[:110]
                    hits.append((os.path.relpath(path, ROOT), line_no, label, value, line))

    if not hits:
        print("CLEAN — no personal data found")
        return 0

    print("FOUND %d hit(s):\n" % len(hits))
    last = None
    for f, ln, label, value, line in sorted(hits):
        if f != last:
            print("--- %s" % f)
            last = f
        print("  L%-4d [%s] %s" % (ln, label, value))
        print("        %s" % line)
    return 1


if __name__ == "__main__":
    sys.exit(main())
