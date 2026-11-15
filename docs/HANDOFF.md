# Handoff: Adapt Hotspot Plus to OnePlus 8T / Android 16

> **设计状态：已定稿。** 本文件保留为设备事实和风险记录，不再作为待决策清单。
> 已确认的设计见 `GLOSSARY.md`、`docs/adr/` 和 `docs/ACCEPTANCE.md`。
> 下一步是实现，不在设计确认前修改代码。

## Goal

Adapt the upstream `hotspot_plus` project into a production-ready Magisk module
for this phone:

- show hotspot gateway and phone hotspot-interface IP;
- list every connected hotspot client with LAN IPv4, MAC, hostname/remark;
- let the user bind a client MAC to a fixed LAN IPv4 that survives reconnect;
- provide a usable Android UI and a Magisk-compatible boot/restore path.

The next session starts with `$grill-with-docs`. It must first run the
`grilling` and `domain-modeling` skills, ask the decision questions, and write
the resulting glossary/ADRs. **Do not start implementation until the user
confirms the design is settled.**

## Workspace

- Full clone: `E:\Project\hotspot_plus`
- Upstream: https://github.com/huanghaiyangyy/hotspot_plus
- Upstream commit: `0c48154e7c7c68adc0b25d7ccf9608a2715aaa10`
- Tag: `v0.2.1`
- The repository is a full clone (`is-shallow-repository=false`), but upstream
  history contains exactly one commit, so there are no earlier commits to study.
- Current clone is clean except for the untracked `docs/` evidence directory.
- License: no license file in the upstream repo. This is a redistribution and
  modification risk that must be resolved before publishing.

## Device facts (verified)

- OnePlus 8T KB2000, arm64-v8a
- Android 16, SDK 36, build `BP4A.251205.006`
- Magisk 31.1 (`31.1:MAGISK:R`), SELinux `Enforcing`
- Root shell: `uid=0`, context `u:r:magisk:s0`; PATH is non-empty in a real
  script run and `/data/adb` is readable
- Magisk busybox 1.36.1.1, with `udhcpd`, `dumpleases`, `ip`, `flock`
- `iptables` 1.8.11 legacy, output-owner match works
- Hotspot interface: `wlan2`; current gateway/phone IP: `192.168.42.1/24`
- Existing hotspot clients observed at `.10`, `.94`, `.211` before testing
- Existing modules include Vector, droidspaces, hosts, and the older
  `oneplus8t_fixed_hotspot`

ADB binary:
`E:\Agent\codex\ROOT\platform-tools\platform-tools\adb.exe`

Use `-s <serial>` and prefer a pushed `.sh` script over inline
`su -c "..."`. On this host PowerShell quote expansion has repeatedly mangled
inline `su -c` commands; use:

```powershell
adb -s <serial> push script.sh /data/local/tmp/script.sh
adb -s <serial> shell 'su -c /system/bin/sh /data/local/tmp/script.sh'
```

Do not hardcode the serial in project docs; redact it.

## What was already proven

The following was tested on this device with a temporary install. It is
evidence that the architecture works, not a finished implementation:

- the module can read `wlan2` and `192.168.42.1/24`;
- it can enumerate clients from `ip neigh` and `dumpsys` data;
- it can run `udhcpd` from Magisk busybox;
- it can replace the system DHCP responder with the module's DHCP responder
  while the system tethering stack keeps NAT/forwarding intact;
- a static lease `AA:BB:CC:DD:EE:FF -> 192.168.42.50` was actually handed out
  after the client reconnected (MAC and remark redacted here);
- two other clients received `.168` and `.169` from the replacement DHCP server.

Raw evidence: `E:\Project\hotspot_plus\docs\device-evidence.txt`

Important experimental caveats:

- the temporary test used an edited copy of upstream defaults;
- `FIXED_GATEWAY=0`, `ENFORCE_GATEWAY=0`, `DHCP_ENABLE=1` during the lease test;
- the fixed-gateway request via `TetheringRequest` was **not** tested on this
  device in this session;
- boot-time automatic startup of the module was **not** tested;
- the app UI was **not** installed/tested;
- the test module and test DHCP state have been removed from the phone.

## What still exists on the phone

- The older, separate system-overlay project
  `E:\Agent\codex\ROOT\oneplus8t-fixed-hotspot` is still installed. Its helper
  package is `com.codex.oneplus8t.hotspotboot` from
  `/system/priv-app/HotspotBoot/HotspotBoot.apk`, with
  `TETHER_PRIVILEGED` granted.
- That older module pins the hotspot subnet by patching the tethering APEX and
  optionally starts the hotspot at boot after a one-time SIM check.
- It overlaps with this project's responsibilities. Decide whether to:
  (a) keep it only for boot-time hotspot startup,
  (b) fold its helper into `hotspot_plus`, or
  (c) retire it after the new module owns both.
- Do not remove or modify it before the user decides. Its readme/handoff:
  `E:\Agent\codex\ROOT\oneplus8t-fixed-hotspot\README.md`
  `E:\Agent\codex\ROOT\oneplus8t-fixed-hotspot\HANDOFF.md`

## Upstream gaps for this target

The upstream is explicitly a KernelSU/Xiaomi HyperOS project. At minimum,
review and adapt:

1. **SELinux**: upstream notes claim rules for KernelSU's `su` domain; the
   module's `sepolicy.rule` must be re-evaluated for Magisk
   `u:r:magisk:s0`.
2. **Tethering reflection**: `hsctl.jar` reflects hidden `TetheringManager`
   interfaces. Verify the signatures on this exact Android 16 build before
   relying on fixed-gateway or start/stop.
3. **Boot lifecycle**: upstream `service.sh` waits for boot completion and
   starts the daemon; confirm behavior with Magisk 31.1, credential-encrypted
   storage, and `/data/adb` visibility.
4. **Line endings**: upstream files may be CRLF; earlier tests failed with
   `syntax error: unexpected word (expecting "do")`. Normalize shipped shell
   files to LF.
5. **Package identity**: upstream launcher is `com.hsp.hotspotplus`, while the
   older system helper is `com.codex.oneplus8t.hotspotboot`. Avoid an ambiguous
   user-facing name/signing/update path.
6. **Default network**: do not silently move the user's hotspot from
   `192.168.42.0/24` to upstream's `192.168.4.0/24`. Either preserve the
   current subnet or ask explicitly.
7. **Runtime state**: static leases live under `/data/adb/hotspot_plus`.
   Decide backup/restore, uninstall behavior, and upgrade migration.
8. **Security**: `RootShell` in the app is a long-lived root shell bridge; the
   WebView loads a local page. Audit exported interfaces, JavaScript bridge,
   shell argument handling, and whether the app can be driven by another app.
9. **Licensing**: no upstream license. Do not assume permission to publish a
   derivative.

## Questions the next session must grill first

These are decisions, not facts. Ask them in rounds and record the answers in
`GLOSSARY.md` / `docs/adr/`.

1. **Ownership boundary**: should the new module absorb the older
   `oneplus8t_fixed_hotspot` boot helper, or depend on it?
2. **Hotspot lifecycle**: must the hotspot auto-start at boot (SIM present),
   or should the app only manage an already-running hotspot?
3. **IP policy**: preserve the current `192.168.42.0/24`, adopt
   `192.168.4.0/24`, or make it configurable with a safe default?
4. **UI surface**: ship the upstream WebView app, a native Kotlin/Compose UI,
   or make the app a thin shell around a documented CLI/WebUI?
5. **Trust model**: is a long-lived root shell acceptable, or should the app
   use a narrow privileged API / helper broadcast?
6. **Update/distribution**: private personal module only, or publishable
   derivative? This determines how hard the license/signing questions are.
7. **Failure policy**: if `udhcpd` or iptables takeover fails, should it fall
   back silently to system DHCP, block the hotspot, or show an error?
8. **Compatibility scope**: this exact KB2000 build only, or a general Magisk
   Android 15/16 module?

## Suggested work split (for multi-agent orchestration)

Only after the design round is answered:

- **Agent A — platform/SELinux**: verify Magisk domain rules, Tethering binder
  signatures, boot timing; produce a probe report and minimal policy diff.
- **Agent B — DHCP takeover**: harden `udhcpd` + iptables ownership; handle
  races, renewal, daemon crash, hotspot on/off, and rollback; add tests.
- **Agent C — UI/app**: adapt package identity, root bridge, client list,
  static-lease editor, status/error states, and WebView security review.
- **Agent D — install/upgrade**: Magisk installer, LF normalization,
  migration from upstream/KernelSU, uninstall, and coexistence with
  `oneplus8t_fixed_hotspot`.
- **Verifier**: independent device test with a clean install, reboot,
  client reconnect, DHCP failure injection, and uninstall rollback.

Do not let more than one agent write the same files. Suggested disjoint write
sets:

- `lib/`, `bin/hspd`, `sepolicy.rule` — DHCP/platform
- `app/`, `webroot/` — UI
- `customize.sh`, `service.sh`, `uninstall.sh`, `module.prop`, docs — packaging

## Acceptance criteria

- Fresh install on the 8T, reboot, hotspot enabled, module status healthy.
- Gateway and phone IP are shown correctly (expected `192.168.42.1` unless
  the user chooses otherwise).
- At least 3 clients are listed with correct IPv4/MAC; stale entries are
  labeled, not hidden or invented.
- A bound MAC gets its chosen IP after "forget network" + reconnect; its old
  lease is not handed out again.
- If the replacement DHCP dies, clients either recover via system DHCP or the
  UI shows a clear failure; no silent dead hotspot.
- Uninstall removes iptables takeover and daemons, and a reboot returns the
  hotspot to stock behavior.
- No secrets, Wi-Fi passwords, or personal client names in the repo.

## Suggested skills

The next agent must call `$grill-with-docs` first. That skill in turn requires
`grilling` and `domain-modeling`. Use `$research` only for unresolved
platform facts. Use `$codebase-design` when deciding module boundaries.

## Reference artifacts

- Evidence: `E:\Project\hotspot_plus\docs\device-evidence.txt`
- Legacy package dump:
  `E:\Project\hotspot_plus\docs\legacy-hotspotboot-package.txt`
- Older module: `E:\Agent\codex\ROOT\oneplus8t-fixed-hotspot\README.md`
- Device setup notes: `E:\Agent\codex\ROOT\android-setup\README.md`
