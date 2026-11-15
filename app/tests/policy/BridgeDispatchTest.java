package com.lixkrt.hotspotplus;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Base64;
import java.util.List;

/** Host test for the bridge's non-eval dispatch and import expansion invariants. */
public final class BridgeDispatchTest {
    private static int failures;

    public static void main(String[] args) throws Exception {
        String main = new String(Files.readAllBytes(Paths.get(
                "app/src/com/lixkrt/hotspotplus/MainActivity.java")), StandardCharsets.UTF_8);
        String root = new String(Files.readAllBytes(Paths.get(
                "app/src/com/lixkrt/hotspotplus/RootShell.java")), StandardCharsets.UTF_8);
        check("bridge has no eval", !main.contains("eval(") && !main.contains("eval \"")
                && !root.contains("eval \"") && !root.contains("eval("));
        check("bridge uses argv dispatch", main.contains("execArgv("));
        check("executor has eval guard", root.contains("unsafeArg(") && root.contains("argvLine("));
        check("executor uses single quotes", root.contains("sq(arg)"));
        int finish = main.indexOf("bridge.needsInstall()");
        int install = main.indexOf("installBridges();", finish);
        check("bridge installs after finished trusted page", finish >= 0 && install > finish);
        check("load path never installs early", !main.contains("loadingDocument(BASE_URL) == BridgeLifecycle.Action.INSTALL"));
        check("page callbacks never install bridges", !main.contains("installBridgesIfCurrent"));
        String html = new String(Files.readAllBytes(Paths.get("webroot/index.html")), StandardCharsets.UTF_8);
        check("webui waits for bridge readiness", html.contains("bridgeReady"));
        check("webui never reloads to recover bridge", !html.contains("location.reload()"));

        List<String> argv = CommandPolicy.parse(CommandPolicy.CLI + " lease import " + b64(
                "aa:bb:cc:dd:ee:ff 192.168.42.10 phone\n"));
        check("import parses", argv != null && argv.get(1).equals("lease") && argv.get(2).equals("import"));
        if (argv != null) {
            String text = CommandPolicy.decodeImport(argv.get(3));
            check("import is canonical", text.equals("aa:bb:cc:dd:ee:ff 192.168.42.10 phone\n"));
        }
        check("injected lease rejected", CommandPolicy.parse(CommandPolicy.CLI + " lease import " + b64(
                "aa:bb:cc:dd:ee:ff 192.168.42.10 ok\n$(touch /tmp/hsp-pwned)\n")) == null);
        List<String> status = CommandPolicy.parse(CommandPolicy.CLI + " status --json");
        check("valid status argv", status != null && status.size() == 3
                && status.get(0).equals(CommandPolicy.CLI)
                && status.get(1).equals("status") && status.get(2).equals("--json"));
        check("valid lease add argv", CommandPolicy.parse(
                CommandPolicy.CLI + " lease add aa:bb:cc:dd:ee:ff 192.168.42.10 phone") != null);
        System.out.println("bridge dispatch: " + (failures == 0 ? "ok" : failures + " failed"));
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
