package com.lixkrt.hotspotplus;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Base64;
import java.util.List;

/** Executes the same fixed command templates used by the app on a host shell. */
public final class DispatchIntegrationTest {
    private static int failures;

    public static void main(String[] args) throws Exception {
        List<List<String>> load = BridgeCommands.pageLoad();
        check("page load present argv", load.get(1).equals(
                Arrays.asList("cat", BridgeCommands.PAGE)));
        check("page load absent argv", load.get(0).equals(
                Arrays.asList("test", "-f", BridgeCommands.DISABLE)));
        check("page load has no sh -c", !load.get(0).contains("-c") && !load.get(1).contains("-c"));

        List<String> toggle = BridgeCommands.toggle(BridgeCommands.HSP);
        check("toggle is fixed argv", toggle.equals(
                Arrays.asList(BridgeCommands.HSP, "toggle")));
        check("toggle has no shell", !toggle.contains("-c") && !toggle.contains("sh"));

        List<String> status = CommandPolicy.parse(CommandPolicy.CLI + " status --json");
        check("status is fixed argv", status != null && status.equals(
                Arrays.asList(BridgeCommands.HSP, "status", "--json")));

        List<String> add = CommandPolicy.parse(CommandPolicy.CLI
                + " lease add aa:bb:cc:dd:ee:ff 192.168.42.10 phone");
        check("lease add is fixed argv", add != null && add.size() == 6
                && add.get(1).equals("lease") && add.get(2).equals("add"));

        String encoded = Base64.getEncoder().encodeToString(
                "aa:bb:cc:dd:ee:ff 192.168.42.10 phone\n".getBytes(StandardCharsets.UTF_8));
        List<String> imp = CommandPolicy.parse(CommandPolicy.CLI + " lease import " + encoded);
        check("import parses canonically", imp != null && imp.size() == 4
                && CommandPolicy.decodeImport(imp.get(3)).contains("aa:bb:cc:dd:ee:ff 192.168.42.10 phone"));
        List<String> file = BridgeCommands.importFile(BridgeCommands.HSP, BridgeCommands.LEASE_IMPORT);
        check("import-file is fixed argv", file.equals(Arrays.asList(
                BridgeCommands.HSP, "lease", "import-file", BridgeCommands.LEASE_IMPORT)));
        check("stage is fixed argv", BridgeCommands.stageImport(BridgeCommands.HSP, BridgeCommands.LEASE_IMPORT)
                .equals(Arrays.asList(BridgeCommands.HSP, "lease", "stage", BridgeCommands.LEASE_IMPORT)));

        check("eval payload rejected", CommandPolicy.parse(CommandPolicy.CLI + " set DNS=\"$(id)\"") == null);
        check("newline rejected", CommandPolicy.parse(CommandPolicy.CLI + " set DNS=1.1.1.1\nid") == null);
        check("malicious import rejected", CommandPolicy.parse(CommandPolicy.CLI + " lease import "
                + Base64.getEncoder().encodeToString("$(touch /tmp/hsp-pwned)\n".getBytes(StandardCharsets.UTF_8))) == null);
        check("no unsafe path", !load.get(1).contains("-c") && !file.contains("-c") && !toggle.contains("-c"));
        executeWhenPosix();
        System.out.println("dispatch integration: " + (failures == 0 ? "ok" : failures + " failed"));
        if (failures != 0) System.exit(1);
    }

    private static void check(String name, boolean ok) {
        if (!ok) {
            failures++;
            System.err.println("FAIL " + name);
        }
    }

    private static void executeWhenPosix() throws Exception {
        String sh = System.getenv("HSP_POSIX_SH");
        String cat = System.getenv("HSP_CAT");
        String trueCmd = System.getenv("HSP_TRUE");
        if (sh == null || cat == null || trueCmd == null) {
            System.out.println("dispatch integration: execution skipped (POSIX command env unset)");
            return;
        }
        RootShell shell = new RootShell(new String[] {sh}, false, 1);
        java.nio.file.Path tmp = java.nio.file.Files.createDirectories(
                java.nio.file.Paths.get("/tmp/hsp-dispatch-" + System.nanoTime()));
        try {
            java.nio.file.Path page = tmp.resolve("index.html");
            java.nio.file.Files.write(page, "<html>module ui</html>".getBytes(StandardCharsets.UTF_8));
            check("executed page load", exec(shell, Arrays.asList(cat, String.valueOf(page))).contains("module ui"));
            check("executed page absent", runCode(shell, Arrays.asList(
                    cat, String.valueOf(tmp.resolve("missing")))) != 0);
            check("executed toggle", runCode(shell, Arrays.asList(
                    trueCmd, "toggle")) == 0);
            check("executed status", runCode(shell, Arrays.asList(
                    trueCmd, "status", "--json")) == 0);
            check("executed lease add", runCode(shell, Arrays.asList(
                    trueCmd, "lease", "add", "aa:bb:cc:dd:ee:ff",
                    "192.168.42.10", "phone")) == 0);
        } finally {
            try (java.util.stream.Stream<java.nio.file.Path> paths = java.nio.file.Files.walk(tmp)) {
                paths.sorted(java.util.Comparator.reverseOrder()).forEach(p -> {
                    try { java.nio.file.Files.deleteIfExists(p); } catch (Exception ignored) {}
                });
            }
        }
    }

    private static String exec(RootShell shell, List<String> argv) throws Exception {
        java.util.concurrent.CompletableFuture<RootShell.Result> f =
                new java.util.concurrent.CompletableFuture<>();
        shell.execArgv(argv, f::complete);
        return f.get(10, java.util.concurrent.TimeUnit.SECONDS).out;
    }

    private static int runCode(RootShell shell, List<String> argv) throws Exception {
        java.util.concurrent.CompletableFuture<RootShell.Result> f =
                new java.util.concurrent.CompletableFuture<>();
        shell.execArgv(argv, f::complete);
        return f.get(10, java.util.concurrent.TimeUnit.SECONDS).code;
    }
}
