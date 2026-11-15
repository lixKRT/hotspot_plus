#!/usr/bin/env python3
"""Offline tests for the platform-probe report parser."""

import json
import shutil
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PROBE = ROOT / "tools" / "probe-8t.sh"
REPORT = ROOT / "tools" / "probe_report.py"


class ProbeReportTest(unittest.TestCase):
    def run_report(self, *args):
        return subprocess.run(
            [sys.executable, str(REPORT), *map(str, args)],
            cwd=ROOT,
            text=True,
            encoding="utf-8",
            capture_output=True,
            check=False,
        )

    def test_probe_script_syntax(self):
        self.assertTrue(PROBE.is_file(), "probe-8t.sh must exist")
        shell = shutil.which("sh")
        if not shell:
            windows_bash = Path("C:/Windows/system32/bash.exe")
            self.assertTrue(
                windows_bash.is_file(),
                "need sh or the Windows WSL bash entry point for shell syntax",
            )
            target = "/mnt/" + str(PROBE).replace("\\", "/")[0].lower() + str(PROBE)[2:].replace("\\", "/")
            shell = str(windows_bash)
            args = [shell, "-n", target]
        else:
            args = [shell, "-n", str(PROBE)]
        result = subprocess.run(
            args,
            text=True,
            encoding="utf-8",
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_parser_builds_status_summary_and_redacts(self):
        fixture = self.enter("fixture")
        fixture.write_text(
            "\n".join(
                [
                    "HSP_PROBE=1",
                    "STATUS|build.identity|PASS|family=OnePlus model=KB2000 Android 16 SDK 36 build=<REDACTED>",
                    "STATUS|root.context|PASS|uid=0 context=u:r:magisk:s0",
                    "STATUS|busybox.tools|PASS|udhcpd,dumpleases,ip,flock",
                    "STATUS|tethering.signatures|PASS|startTethering found",
                    "STATUS|fixed_gateway.request|UNVERIFIED|needs a later ticket",
                    "STATUS|callback.magisk_domain|PASS|no denial",
                    "STATUS|boot.timing|PASS|boot completed",
                    "STATUS|dhcp.takeover|PASS|cleaned up",
                    "SSID|HomeNet",
                    "MAC|AA:BB:CC:DD:EE:01",
                    "SERIAL|SYNTHETIC-SERIAL-NOT-A-DEVICE",
                    "PASSWORD|SYNTHETIC-SECRET",
                    "BUILD|model=KB2000",
                    "BUILD|fingerprint=SyntheticVendor/SyntheticDevice:16/SYNTHETIC.BUILD/ID:user/release-keys",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        output = self.enter("summary.json")

        result = self.run_report(fixture, "--json", output)

        self.assertEqual(result.returncode, 0, result.stderr)
        text = output.read_text(encoding="utf-8")
        self.assertNotIn("SYNTHETIC-SERIAL-NOT-A-DEVICE", text)
        self.assertNotIn("AA:BB:CC:DD:EE:01", text)
        self.assertNotIn("HomeNet", text)
        self.assertNotIn("SYNTHETIC-SECRET", text)
        self.assertNotIn("SYNTHETIC.BUILD", text)
        summary = json.loads(text)
        self.assertEqual(summary["overall"], "PARTIAL")
        self.assertEqual(summary["counts"], {"PASS": 7, "FAIL": 0, "UNVERIFIED": 1})
        self.assertEqual(summary["checks"][4]["status"], "UNVERIFIED")
        self.assertNotIn("BUILD", summary["facts"])

    def test_parser_rejects_unknown_status(self):
        fixture = self.enter("bad.txt")
        fixture.write_text("STATUS|build.identity|MAYBE|oops\n", encoding="utf-8")

        result = self.run_report(fixture, "--json", self.enter("out.json"))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown status", result.stderr.lower())

    def test_markdown_report_explains_unverified_and_cleanup(self):
        fixture = self.enter("facts.txt")
        fixture.write_text(
            "\n".join(
                [
                    "STATUS|fixed_gateway.request|UNVERIFIED|needs later ticket",
                    "CLEANUP|dhcp.takeover|temporary chain removed; system DHCP restored",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        output = self.enter("report.md")

        result = self.run_report(fixture, "--markdown", output)

        self.assertEqual(result.returncode, 0, result.stderr)
        text = output.read_text(encoding="utf-8")
        self.assertIn("UNVERIFIED", text)
        self.assertIn("temporary chain removed", text)
        self.assertIn("fixed_gateway.request", text)

    def test_result_status_is_not_mistaken_for_a_device_identifier(self):
        fixture = self.enter("callback.txt")
        fixture.write_text(
            "CALLBACK|binder_callback=PASS isTetheringSupported_result=0\n",
            encoding="utf-8",
        )
        output = self.enter("callback.json")

        result = self.run_report(fixture, "--json", output)

        self.assertEqual(result.returncode, 0, result.stderr)
        summary = json.loads(output.read_text(encoding="utf-8"))
        self.assertIn("binder_callback=PASS", summary["facts"]["CALLBACK"][0])
        self.assertIn("isTetheringSupported_result=0", summary["facts"]["CALLBACK"][0])

    def enter(self, name):
        import tempfile

        if not hasattr(self, "_tmp"):
            self._tmp = tempfile.TemporaryDirectory()
        return Path(self._tmp.name) / name

    def tearDown(self):
        if hasattr(self, "_tmp"):
            self._tmp.cleanup()


if __name__ == "__main__":
    unittest.main()
