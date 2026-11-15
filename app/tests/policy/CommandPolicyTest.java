package com.lixkrt.hotspotplus;

import java.nio.charset.StandardCharsets;
import java.util.Base64;

public final class CommandPolicyTest {
    private static int failures;
    private static final String PREFIX = "LOCK_WAIT=20 sh /data/adb/modules/hotspot_plus/bin/hsp ";

    public static void main(String[] args) {
        check("status allowed", CommandPolicy.allowed("status --json", true));
        check("toggle allowed", CommandPolicy.allowed("toggle", true));
        check("daemon restart allowed", CommandPolicy.allowed("daemon restart", true));
        check("arbitrary shell rejected", !CommandPolicy.allowed("rm -rf /", true));
        check("command chaining rejected", !CommandPolicy.allowed("status --json; id", true));
        check("substitution rejected", !CommandPolicy.allowed("status --json $(id)", true));
        check("plain shell metacharacters rejected", !CommandPolicy.allowed("status | id", true));
        check("arbitrary env rejected", !CommandPolicy.allowed("set FOO=bar", true));
        check("poll interval allowed", CommandPolicy.allowed("set POLL_INTERVAL=5", true));
        check("valid lease deletion allowed", CommandPolicy.allowed("lease del aa:bb:cc:dd:ee:ff", true));
        check("hsp arbitrary subcommand rejected", !CommandPolicy.allowed("hsctl start", true));
        check("untrusted document rejected", !CommandPolicy.allowed("status --json", false));
        check("empty command rejected", !CommandPolicy.allowed("  ", true));
        check("quoted command substitution rejected",
                !CommandPolicy.allowed("set DNS=\"$(id)\"", true));
        check("backtick substitution rejected",
                !CommandPolicy.allowed("set DNS=`id`", true));
        check("semicolon rejected",
                !CommandPolicy.allowed("set DNS=1.1.1.1;id", true));
        check("pipe rejected",
                !CommandPolicy.allowed("set DNS=1.1.1.1|id", true));
        check("newline rejected",
                !CommandPolicy.allowed("set DNS=1.1.1.1\nid", true));
        check("malicious lease import rejected",
                !CommandPolicy.allowed("lease import " + b64(
                        "aa:bb:cc:dd:ee:ff 192.168.42.10 ok\n$(touch /tmp/hsp-pwned)\n"), true));
        check("valid wrapped status allowed",
                CommandPolicy.allowed(PREFIX + "status --json", true));
        check("valid lease add allowed",
                CommandPolicy.allowed(PREFIX + "lease add aa:bb:cc:dd:ee:ff 192.168.42.10 phone", true));
        check("valid lease import allowed",
                CommandPolicy.allowed("lease import " + b64(
                        "aa:bb:cc:dd:ee:ff 192.168.42.10 phone\n"), true));
        System.out.println("command policy: " + (failures == 0 ? "ok" : failures + " failed"));
        if (failures != 0) System.exit(1);
    }

    private static String b64(String s) {
        return Base64.getEncoder().encodeToString(s.getBytes(StandardCharsets.UTF_8));
    }

    private static void check(String name, boolean ok) {
        if (!ok) {
            failures++;
            System.err.println("FAIL " + name);
        }
    }
}
