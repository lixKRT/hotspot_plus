# Platform probe harness

Read-only/reversible probes for the OnePlus 8T platform gate (issue #2).
This directory is diagnostic tooling, not the hotspot adaptation.

## Prerequisites

- Python 3.9+ on the host.
- `adb` and a rooted target device where `su` lands in `u:r:magisk:s0`.
- `android.jar` and `d8` for building the callback probe:
  `ANDROID_HOME/platforms/android-36/android.jar` and
  `ANDROID_HOME/build-tools/36.0.0/d8.bat`.

The target serial must be supplied per command. Never add it to this repo.

## Build the callback probe

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/build-callback-probe.ps1 -Output build/callback-probe.jar
```

## Run

Push the probe script, the existing `hsctl.jar`, and the callback probe:

```powershell
$adb = "path\to\adb.exe"
$serial = "<device-serial>"
& $adb -s $serial push tools/probe-8t.sh /data/local/tmp/probe-8t.sh
& $adb -s $serial push bin/hsctl.jar /data/local/tmp/hsctl.jar
& $adb -s $serial push build/callback-probe.jar /data/local/tmp/callback-probe.jar
```

Run it through a real root shell, as HANDOFF requires:

```powershell
& $adb -s $serial shell 'su -c /system/bin/sh /data/local/tmp/probe-8t.sh' |
    Tee-Object "$env:USERPROFILE\.codex\hotspot_plus-notes\02-platform-probes\probe.facts.txt"
```

Build the checked-in reports:

```powershell
python tools/probe_report.py `
  "$env:USERPROFILE\.codex\hotspot_plus-notes\02-platform-probes\probe.facts.txt" `
  --json docs/probes/02-platform-summary.json
python tools/probe_report.py `
  "$env:USERPROFILE\.codex\hotspot_plus-notes\02-platform-probes\probe.facts.txt" `
  --markdown "$env:TEMP\02-platform-report.generated.md"
```

The Markdown output is a compact table. The checked-in
`docs/probes/02-platform-report.md` adds commands, impact, cleanup notes and
UNVERIFIED reasons; update it when new probe evidence lands.

## Safety

- The probe reads identity, root, SELinux, busybox, binder, boot and interface
  facts.
- It creates only a uniquely named temporary iptables chain and a temporary
  `udhcpd` configuration under `/data/local/tmp`.
- Both are removed by an exit trap; pre-existing rules and the legacy module
  are never modified.
- It does not install, flash, toggle the hotspot, or test fixed-gateway
  adoption. Anything requiring those actions stays UNVERIFIED for a later
  ticket.

## Offline tests

```powershell
python -m unittest discover -s tools/tests -v
```

The suite checks the probe shell syntax, parser/redaction behavior, strict
three-state status validation, and Markdown cleanup output. It needs no device.
