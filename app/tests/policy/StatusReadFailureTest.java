package com.lixkrt.hotspotplus;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/**
 * Regression test for the WebUI status path: the app's persistent root shell must return each
 * framed command completely, including when several status reads overlap on the shell pool.
 */
public final class StatusReadFailureTest {
    private static int failures;

    public static void main(String[] args) throws Exception {
        java.nio.file.Path tmp = Files.createTempDirectory("hsp-status-read-");
        try {
            java.nio.file.Path hsp = tmp.resolve("hsp");
            Files.write(hsp, script().getBytes(StandardCharsets.UTF_8));
            hsp.toFile().setExecutable(true);
            String sh = System.getenv().getOrDefault("HSP_TEST_SH", "sh");
            java.nio.file.Path crlfSh = tmp.resolve("sh-crlf");
            Files.write(crlfSh, crlfShell(sh).getBytes(StandardCharsets.UTF_8));
            crlfSh.toFile().setExecutable(true);
            RootShell shared = new RootShell(new String[] {sh, crlfSh.toString()}, false, 6);
            ExecutorService callers = Executors.newFixedThreadPool(6);
            try {
                for (int i = 0; i < 8; i++) {
                    List<CompletableFuture<RootShell.Result>> batch = new ArrayList<>();
                    for (int worker = 0; worker < 6; worker++) {
                        CompletableFuture<RootShell.Result> result = new CompletableFuture<>();
                        batch.add(result);
                        final int id = worker;
                        callers.execute(() -> {
                            try {
                                shared.execArgv(Arrays.asList(hsp.toString(), "status", "--json"),
                                        r -> result.complete(after(r, id)));
                            } catch (RuntimeException e) {
                                result.completeExceptionally(e);
                            }
                        });
                    }
                    for (CompletableFuture<RootShell.Result> result : batch) {
                        RootShell.Result status = result.get(20, TimeUnit.SECONDS);
                        check("round " + i + " status exit", status.code == 0);
                        String json = lastJson(status.out);
                        check("round " + i + " status parseable", json != null);
                        check("round " + i + " status complete", json != null
                                && json.contains("\"version\":\"v0.3.0\""));
                        check("round " + i + " status stderr empty", status.err.trim().isEmpty());
                    }
                }
            } finally {
                callers.shutdownNow();
            }
            check("all concurrent status reads returned", total.get() == 48);
        } finally {
            try (java.util.stream.Stream<java.nio.file.Path> paths = Files.walk(tmp)) {
                paths.sorted(java.util.Comparator.reverseOrder()).forEach(path -> {
                    try {
                        Files.deleteIfExists(path);
                    } catch (Exception ignored) {
                    }
                });
            }
        }
        System.out.println("status read failure: " + (failures == 0 ? "ok" : failures + " failed"));
        if (failures != 0) System.exit(1);
    }

    private static final java.util.concurrent.atomic.AtomicInteger total =
            new java.util.concurrent.atomic.AtomicInteger();

    private static RootShell.Result after(RootShell.Result r, int id) {
        total.incrementAndGet();
        return r;
    }

    private static RootShell.Result call(RootShell shell, java.util.List<String> argv) throws Exception {
        CompletableFuture<RootShell.Result> result = new CompletableFuture<>();
        if (!new java.io.File(argv.get(0)).canExecute() || !new java.io.File(argv.get(0)).setExecutable(true)) {
            throw new IllegalStateException("fixture is not executable: " + argv.get(0));
        }
        shell.execArgv(argv, result::complete);
        return result.get(15, TimeUnit.SECONDS);
    }

    private static String script() {
        return "#!/bin/sh\n"
                + "case \"$1\" in\n"
                + "  status) printf '%s\\n' '{\"ap\":true,\"iface\":\"wlan0\",\"addr\":\"192.168.42.1/24\",\"version\":\"v0.3.0\"}' ;;\n"
                + "  clients) printf '%s\\n' '{\"ap\":true,\"clients\":[]}' ;;\n"
                + "  config) printf '%s\\n' '{\"FIXED_GATEWAY\":\"1\",\"GATEWAY\":\"192.168.42.1\"}' ;;\n"
                + "esac\n";
    }

    /**
     * The device's su channel terminates diagnostic lines with CRLF. Model that at the stream
     * boundary by forwarding this shell's stderr through a CRLF translation.
     */
    private static String crlfShell(String sh) {
        return "#!/bin/sh\n"
                + "exec '" + sh.replace("'", "'\\''") + "' 2> >(sed -u 's/$/\\r/' >&2)\n";
    }

    /** Matches the WebUI's parseJson: only the final stdout line is parsed as JSON. */
    private static String lastJson(String stdout) {
        if (stdout == null) return null;
        String text = stdout.trim();
        int split = text.lastIndexOf('\n');
        String last = (split < 0 ? text : text.substring(split + 1)).trim();
        if (!last.startsWith("{") || !last.endsWith("}")) return null;
        int braces = 0;
        boolean quoted = false, escaped = false;
        for (int i = 0; i < last.length(); i++) {
            char c = last.charAt(i);
            if (quoted) {
                if (escaped) escaped = false;
                else if (c == '\\') escaped = true;
                else if (c == '"') quoted = false;
            } else if (c == '"') {
                quoted = true;
            } else if (c == '{') {
                braces++;
            } else if (c == '}') {
                braces--;
            }
        }
        return braces == 0 && !quoted && !escaped ? last : null;
    }

    private static void check(String name, boolean ok) {
        if (!ok) {
            failures++;
            System.err.println("FAIL " + name);
        }
    }
}
