#!/usr/bin/env python3
"""Parse probe-8t.sh output into a redacted JSON or Markdown report."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from collections import Counter
from pathlib import Path


ALLOWED_STATUSES = {"PASS", "FAIL", "UNVERIFIED"}
SENSITIVE_RE = re.compile(
    r"(?i)\b("
    r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}"
    r"|[0-9a-f]{8,40}"
    r")\b"
)
SERIALISH_RE = re.compile(r"(?i)\b(serial|android_id|device_id)[=: ]+[A-Za-z0-9._:-]+")
SECRETISH_RE = re.compile(
    r"(?i)\b(pass(?:word|phrase)?|psk|ssid|secret|token)\s*[=:]\s*[^\s|]+"
)


def redact(value: str) -> str:
    value = SERIALISH_RE.sub(lambda m: f"{m.group(1)}=<REDACTED>", value)
    value = SECRETISH_RE.sub(lambda m: f"{m.group(1)}=<REDACTED>", value)
    value = SENSITIVE_RE.sub("<REDACTED>", value)
    return value


def parse(path: Path) -> tuple[dict[str, object], list[dict[str, str]]]:
    checks: list[dict[str, str]] = []
    facts: dict[str, list[str]] = {}
    cleanup: list[dict[str, str]] = []

    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw or raw == "HSP_PROBE=1":
            continue
        if raw.startswith("STATUS|"):
            parts = raw.split("|", 3)
            if len(parts) < 3:
                raise ValueError(f"line {lineno}: malformed STATUS record")
            status = parts[2]
            if status not in ALLOWED_STATUSES:
                raise ValueError(f"line {lineno}: unknown status {status!r}")
            checks.append(
                {
                    "id": parts[1],
                    "status": status,
                    "detail": redact(parts[3]) if len(parts) == 4 else "",
                }
            )
        elif raw.startswith("CLEANUP|"):
            parts = raw.split("|", 2)
            if len(parts) != 3:
                raise ValueError(f"line {lineno}: malformed CLEANUP record")
            cleanup.append({"id": parts[1], "detail": redact(parts[2])})
        else:
            kind, _, value = raw.partition("|")
            if value:
                facts.setdefault(kind, []).append(redact(value))

    counts = Counter(check["status"] for check in checks)
    if counts["FAIL"]:
        overall = "FAIL"
    elif counts["UNVERIFIED"]:
        overall = "PARTIAL"
    elif counts["PASS"]:
        overall = "PASS"
    else:
        overall = "UNVERIFIED"

    summary = {
        "overall": overall,
        "counts": {status: counts[status] for status in ("PASS", "FAIL", "UNVERIFIED")},
        "checks": checks,
        "cleanup": cleanup,
        "facts": {key: values for key, values in facts.items() if value_is_public(key)},
    }
    summary["sha256"] = hashlib.sha256(
        json.dumps(summary, sort_keys=True).encode("utf-8")
    ).hexdigest()
    return summary, cleanup


def value_is_public(key: str) -> bool:
    return key.upper() not in {
        "BUILD",
        "SSID",
        "MAC",
        "SERIAL",
        "PASSWORD",
        "PASSPHRASE",
        "RAWDATA",
    }


def render_markdown(summary: dict[str, object]) -> str:
    counts = summary["counts"]
    lines = [
        "# Platform probe report",
        "",
        f"Overall: **{summary['overall']}**",
        "",
        f"PASS: {counts['PASS']}  FAIL: {counts['FAIL']}  UNVERIFIED: {counts['UNVERIFIED']}",
        "",
        "| Check | Status | Detail |",
        "| --- | --- | --- |",
    ]
    for check in summary["checks"]:
        detail = check["detail"].replace("|", "\\|")
        lines.append(f"| `{check['id']}` | **{check['status']}** | {detail} |")

    lines.extend(["", "## Cleanup", ""])
    if summary["cleanup"]:
        for item in summary["cleanup"]:
            lines.append(f"- `{item['id']}`: {item['detail']}")
    else:
        lines.append("- No temporary state was created.")

    lines.extend(["", f"SHA-256: `{summary['sha256']}`", ""])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    output = parser.add_mutually_exclusive_group(required=True)
    output.add_argument("--json", type=Path)
    output.add_argument("--markdown", type=Path)
    args = parser.parse_args()

    try:
        summary, _ = parse(args.input)
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"probe_report: {exc}", file=sys.stderr)
        return 2

    if args.json:
        args.json.write_text(
            json.dumps(summary, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    else:
        args.markdown.write_text(render_markdown(summary), encoding="utf-8")
    return 0 if summary["overall"] != "FAIL" else 1


if __name__ == "__main__":
    raise SystemExit(main())
