package com.lixkrt.hotspotplus;

import java.util.Arrays;

/** Pure-Java checks for argv quoting and the absence of eval in framed commands. */
public final class RootShellFramingTest {
    private static int failures;

    public static void main(String[] args) {
        String line = RootShell.argvLine(Arrays.asList("sh", CommandPolicy.CLI, "status", "--json"));
        check("argv single-quoted", line.equals("'sh' '/data/adb/modules/hotspot_plus/bin/hsp' 'status' '--json'"));
        String frame = RootShell.frameArgv(line, "__HSP_END_TEST");
        check("argv frame has no eval", !frame.contains("eval"));
        check("argv frame invokes literal words", frame.contains("'status' '--json'"));
        check("commands cannot use substitution", !CommandPolicy.allowed("set DNS=\"$(id)\"", true));
        check("commands cannot use backticks", !CommandPolicy.allowed("set DNS=`id`", true));
        check("commands cannot use semicolon", !CommandPolicy.allowed("set DNS=1.1.1.1;id", true));
        check("commands cannot use pipe", !CommandPolicy.allowed("set DNS=1.1.1.1|id", true));
        check("commands cannot use newline", !CommandPolicy.allowed("set DNS=1.1.1.1\nid", true));
        check("executor rejects quote", RootShell.unsafeArg("a'b"));
        check("executor rejects backslash", RootShell.unsafeArg("a\\b"));
        check("executor rejects newline", RootShell.unsafeArg("a\nb"));
        System.out.println("root framing: " + (failures == 0 ? "ok" : failures + " failed"));
        if (failures != 0) System.exit(1);
    }

    private static void check(String name, boolean ok) {
        if (!ok) {
            failures++;
            System.err.println("FAIL " + name);
        }
    }
}
