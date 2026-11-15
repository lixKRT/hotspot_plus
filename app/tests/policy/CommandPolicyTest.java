package com.lixkrt.hotspotplus;

public final class CommandPolicyTest {
    private static int failures;

    public static void main(String[] args) {
        check("status allowed", CommandPolicy.allowed("status --json", true));
        check("toggle allowed", CommandPolicy.allowed("toggle", true));
        check("daemon restart allowed", CommandPolicy.allowed("daemon restart", true));
        check("arbitrary shell rejected", !CommandPolicy.allowed("rm -rf /", true));
        check("command chaining rejected", !CommandPolicy.allowed("status --json; id", true));
        check("substitution rejected", !CommandPolicy.allowed("status --json $(id)", true));
        check("plain shell metacharacters rejected", !CommandPolicy.allowed("status | id", true));
        check("arbitrary env rejected", !CommandPolicy.allowed("set FOO=bar", true));
        check("poll interval allowed", CommandPolicy.allowed("set POLL_INTERVAL='5'", true));
        check("lease mutation rejected", !CommandPolicy.allowed("lease del aa:bb:cc:dd:ee:ff", true));
        check("hsp arbitrary subcommand rejected", !CommandPolicy.allowed("hsctl start", true));
        check("untrusted document rejected", !CommandPolicy.allowed("status --json", false));
        check("empty command rejected", !CommandPolicy.allowed("  ", true));
        System.out.println("command policy: " + (failures == 0 ? "ok" : failures + " failed"));
        if (failures != 0) System.exit(1);
    }

    private static void check(String name, boolean ok) {
        if (!ok) {
            failures++;
            System.err.println("FAIL " + name);
        }
    }
}
