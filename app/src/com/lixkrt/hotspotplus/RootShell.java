package com.lixkrt.hotspotplus;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/**
 * Small pool of persistent root shells ("su" processes). Pure Java (no android.* imports) so it can
 * be unit-tested on a desktop JVM with "sh" instead of "su".
 *
 * Each pool thread owns one long-lived su process; commands are framed with a random marker so
 * stdout/stderr/exit code are recovered exactly. Several shells exist so a long operation
 * (e.g. "hsp on", up to ~1 min) never blocks the UI's status polling.
 *
 * Persistent shell output is line oriented but not necessarily newline-normalised: Android root
 * shells (Magisk / su) often use CRLF. Markers are therefore matched after trimming trailing CR,
 * and both streams are drained concurrently so a full pipe cannot deadlock the reader.
 */
public final class RootShell {

    public static final int EACCES = 13;
    /** Upper bound for a bridge command; operations such as hotspot start may take ~1 minute. */
    static final long COMMAND_TIMEOUT_MS = 95000;
    public static final String DENIED_MSG =
            "未获得 root 权限：请打开 Magisk 应用 →「超级用户」，找到「热点增强」并允许 root，然后回到本应用点「重试」。";

    public static final class Result {
        public final int code;
        public final String out;
        public final String err;
        public final boolean denied;

        public Result(int code, String out, String err, boolean denied) {
            this.code = code;
            this.out = out;
            this.err = err;
            this.denied = denied;
        }

        public String lastLine() {
            String all = (out + "\n" + err).trim();
            int i = all.lastIndexOf('\n');
            return i >= 0 ? all.substring(i + 1).trim() : all;
        }
    }

    public interface Callback {
        void onResult(Result r);
    }

    static final class DeniedException extends IOException {
        DeniedException(String m) {
            super(m);
        }
    }

    /** The command never reached the shell (safe to retry on a fresh shell). */
    static final class WriteFailed extends IOException {
        WriteFailed(String m) {
            super(m);
        }
    }

    private final String[] suCmd;
    private final boolean requireUid0;
    private final ThreadPoolExecutor pool;
    private final ThreadLocal<Shell> local = new ThreadLocal<>();
    private volatile boolean denied;

    public RootShell(String[] suCmd, boolean requireUid0, int maxShells) {
        this.suCmd = suCmd.clone();
        this.requireUid0 = requireUid0;
        pool = new ThreadPoolExecutor(maxShells, maxShells, 90, TimeUnit.SECONDS, new LinkedBlockingQueue<Runnable>(),
                r -> {
                    Thread t = new Thread(() -> {
                        try {
                            r.run();
                        } finally {
                            Shell s = local.get();
                            if (s != null) s.close();
                            local.remove();
                        }
                    }, "rootshell");
                    t.setDaemon(true);
                    return t;
                });
        pool.allowCoreThreadTimeOut(true);
    }

    public boolean isDenied() {
        return denied;
    }

    /**
     * Run a validated argv without eval. Each argument is single-quoted, so no argument can
     * introduce shell syntax or command substitution.
     */
    public void execArgv(List<String> argv, Callback cb) {
        execute(argv, null, cb);
    }

    /** Run fixed argv with body input; bytes are framed separately, never parsed as shell. */
    public void execArgv(List<String> argv, String stdinText, Callback cb) {
        execute(argv, stdinText, cb);
    }

    private void execute(List<String> argv, String stdinText, Callback cb) {
        pool.execute(() -> {
            Result r = doArgv(argv, stdinText);
            cb.onResult(r);
        });
    }

    private Result doArgv(List<String> argv, String stdinText) {
        if (argv == null || argv.isEmpty()) return new Result(126, "", "empty argv", false);
        for (String arg : argv) {
            if (arg == null || unsafeArg(arg)) {
                return new Result(126, "", "unsafe argv", false);
            }
        }
        String line = argvLine(argv);
        for (int attempt = 0; attempt < 2; attempt++) {
            Shell s = local.get();
            if (s == null || !s.alive()) {
                if (s != null) s.close();
                local.remove();
                try {
                    s = new Shell();
                    local.set(s);
                } catch (DeniedException e) {
                    denied = true;
                    return new Result(EACCES, "", DENIED_MSG + "\n(" + e.getMessage() + ")", true);
                } catch (IOException e) {
                    return new Result(1, "", "无法启动 root 权限通道：" + e.getMessage(), false);
                }
            }
            denied = false;
            try {
                return s.runArgv(line, stdinText, COMMAND_TIMEOUT_MS);
            } catch (WriteFailed e) {
                s.close();
                local.remove();
                if (attempt == 1) return new Result(1, "", "root 权限通道异常：" + e.getMessage(), false);
            } catch (IOException e) {
                s.close();
                local.remove();
                return new Result(1, "", "root 权限通道意外退出：" + e.getMessage(), false);
            }
        }
        return new Result(1, "", "未知执行错误", false);
    }

    // ------------------------------------------------------------------ helpers

    static String sq(String s) {
        return "'" + s.replace("'", "'\\''") + "'";
    }

    static boolean unsafeArg(String s) {
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c < 0x20 || c == 0x7f || c == 0x3b || c == 0x7c || c == 0x26 || c == 0x60
                    || c == 0x24 || c == 0x3c || c == 0x3e || c == 0x28 || c == 0x29
                    || c == 0x22 || c == 0x27) return true;
        }
        return false;
    }

    /** Build a shell line from already-validated argv using single-quote escaping only. */
    static String argvLine(List<String> argv) {
        StringBuilder sb = new StringBuilder();
        for (String arg : argv) {
            if (sb.length() > 0) sb.append(' ');
            sb.append(sq(arg));
        }
        return sb.toString();
    }

    /** Frame a single-quoted argv command without eval. */
    static String frameArgv(String argvLine, String marker) {
        return "( " + argvLine + "\n) </dev/null\n"
                + "__hsp_rc=$?; printf '\\n%s %d\\n' " + marker + " \"$__hsp_rc\"; printf '\\n%s\\n' "
                + marker + " >&2\n";
    }

    /** Frame argv whose stdin is supplied by a here-document, never by shell interpolation. */
    static String frameArgvWithStdin(String argvLine, String body, String marker) {
        String end = "__HSP_IN_" + marker;
        return "( " + argvLine + " <<'" + end + "'\n" + body
                + (body.endsWith("\n") ? "" : "\n") + end + "\n) </dev/null\n"
                + "__hsp_rc=$?; printf '\\n%s %d\\n' " + marker + " \"$__hsp_rc\"; printf '\\n%s\\n' "
                + marker + " >&2\n";
    }

    /** Join lines received before the marker (the marker was preceded by an injected "\n"). */
    static String join(List<String> lines) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < lines.size(); i++) {
            if (i > 0) b.append('\n');
            b.append(lines.get(i));
        }
        return b.toString();
    }

    /** Root shells may terminate lines with CRLF; markers are matched on the CR-free line. */
    static String markerLine(String line) {
        return line.endsWith("\r") ? line.substring(0, line.length() - 1) : line;
    }

    /** Reads a stream into '\n'-separated lines (keeps '\r'), UTF-8. */
    static final class LineQueue implements Runnable {
        static final String EOF = new String("\u0000EOF");
        final InputStream in;
        final LinkedBlockingQueue<String> q = new LinkedBlockingQueue<>();

        LineQueue(InputStream in, String name) {
            this.in = in;
            Thread t = new Thread(this, name);
            t.setDaemon(true);
            t.start();
        }

        @Override
        public void run() {
            ByteArrayOutputStream buf = new ByteArrayOutputStream();
            byte[] b = new byte[8192];
            try {
                int n;
                while ((n = in.read(b)) > 0) {
                    for (int i = 0; i < n; i++) {
                        if (b[i] == '\n') {
                            q.add(new String(buf.toByteArray(), StandardCharsets.UTF_8));
                            buf.reset();
                        } else {
                            buf.write(b[i]);
                        }
                    }
                }
            } catch (IOException ignored) {
            }
            if (buf.size() > 0) q.add(new String(buf.toByteArray(), StandardCharsets.UTF_8));
            q.add(EOF);
        }

        String take(long timeoutMs) throws IOException {
            String s;
            try {
                s = timeoutMs > 0 ? q.poll(timeoutMs, TimeUnit.MILLISECONDS) : q.take();
            } catch (InterruptedException e) {
                throw new IOException("interrupted");
            }
            if (s == null) throw new IOException("timeout");
            if (s == EOF) {
                q.add(EOF);
                throw new IOException("shell exited");
            }
            return s;
        }

        /** Non-blocking poll (or bounded poll); null means the stream has no complete line yet. */
        String poll(long timeoutMs) {
            if (timeoutMs <= 0) return q.poll();
            try {
                return q.poll(timeoutMs, TimeUnit.MILLISECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return EOF;
            }
        }

    }

    final class Shell {
        final Process p;
        final OutputStream stdin;
        final LineQueue outQ;
        final LineQueue errQ;
        private final AtomicInteger epoch = new AtomicInteger();

        Shell() throws IOException {
            try {
                p = new ProcessBuilder(suCmd).start();
            } catch (IOException e) {
                // A denied su launch may surface as ENOENT/EACCES.
                throw new DeniedException("su: " + e.getMessage());
            }
            stdin = p.getOutputStream();
            outQ = new LineQueue(p.getInputStream(), "su-out");
            errQ = new LineQueue(p.getErrorStream(), "su-err");
            Result r;
            try {
                r = runArgv("id", null, 60000);
            } catch (IOException e) {
                close();
                throw new DeniedException("su 已退出 (" + e.getMessage() + ")");
            }
            if (requireUid0 && !isRootId(r.out)) {
                close();
                throw new DeniedException("uid=" + r.out.trim());
            }
        }

        boolean alive() {
            try {
                p.exitValue();
                return false;
            } catch (IllegalThreadStateException e) {
                return true;
            }
        }

        Result runArgv(String argvLine, String stdinText, long timeoutMs) throws IOException {
            String marker = "__HSP_END_" + UUID.randomUUID().toString().replace("-", "");
            if (!alive()) throw new WriteFailed("shell not running");
            try {
                String payload = stdinText == null
                        ? frameArgv(argvLine, marker)
                        : frameArgvWithStdin(argvLine, stdinText, marker);
                stdin.write(payload.getBytes(StandardCharsets.UTF_8));
                stdin.flush();
            } catch (IOException e) {
                throw new WriteFailed(e.getMessage());
            }
            return readResult(marker, timeoutMs);
        }

        /**
         * Read stdout and stderr concurrently until both markers arrive. Markers are unique per
         * command and matched after removing a trailing CR: root shells may translate newlines.
         * The overall wait is bounded; timeout is reported unambiguously as a stream stall.
         */
        private Result readResult(String marker, long timeoutMs) throws IOException {
            final int current = epoch.incrementAndGet();
            final ReadSide out = new ReadSide(outQ, true);
            final ReadSide err = new ReadSide(errQ, false);
            Thread outReader = new Thread(() -> readSide(out, marker, current), "rootshell-read-out");
            Thread errReader = new Thread(() -> readSide(err, marker, current), "rootshell-read-err");
            outReader.setDaemon(true);
            errReader.setDaemon(true);
            outReader.start();
            errReader.start();
            long deadline = timeoutMs > 0 ? System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs) : 0;
            synchronized (this) {
                boolean interrupted = false;
                while (!(out.done && err.done)) {
                    if (deadline != 0) {
                        long left = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime());
                        if (left <= 0) break;
                        try {
                            wait(left);
                        } catch (InterruptedException e) {
                            interrupted = true;
                            break;
                        }
                    } else {
                        try {
                            wait();
                        } catch (InterruptedException e) {
                            interrupted = true;
                            break;
                        }
                    }
                }
                if (interrupted) {
                    retire(current);
                    Thread.currentThread().interrupt();
                    throw new IOException("interrupted");
                }
                if (!(out.done && err.done)) {
                    retire(current);
                    String missing = !out.done ? (!err.done ? "stdout+stderr" : "stdout") : "stderr";
                    throw new IOException("timeout waiting for " + missing + " marker");
                }
                if (out.exited || err.exited) {
                    retire(current);
                    throw new IOException("shell exited while reading");
                }
                return new Result(out.code, join(out.lines), join(err.lines), false);
            }
        }

        /** Invalidate any reader still parked on this run so it cannot eat the next command. */
        private void retire(int current) {
            epoch.compareAndSet(current, current + 1);
        }

        private void readSide(ReadSide side, String marker, int runEpoch) {
            try {
                while (true) {
                    if (runEpoch != epoch.get()) {
                        side.exited = true;
                        return;
                    }
                    String raw = side.queue.poll(100);
                    if (runEpoch != epoch.get()) {
                        side.exited = true;
                        return;
                    }
                    if (raw != null) {
                        processLine(side, marker, raw);
                        if (side.done) return;
                    } else if (!alive()) {
                        side.exited = true;
                        return;
                    }
                }
            } finally {
                synchronized (Shell.this) {
                    side.done = true;
                    Shell.this.notifyAll();
                }
            }
        }

        private void processLine(ReadSide side, String marker, String raw) {
            if (raw == LineQueue.EOF) {
                side.exited = true;
                side.done = true;
                return;
            }
            String line = markerLine(raw);
            if (side.isStdout) {
                if (line.startsWith(marker + " ")) {
                    try {
                        side.code = Integer.parseInt(line.substring(marker.length() + 1).trim());
                    } catch (NumberFormatException e) {
                        side.code = 1;
                    }
                    side.done = true;
                } else {
                    side.lines.add(raw);
                }
            } else if (line.equals(marker)) {
                side.done = true;
            } else {
                side.lines.add(raw);
            }
        }

        private final class ReadSide {
            final LineQueue queue;
            final boolean isStdout;
            final List<String> lines = new ArrayList<>();
            volatile boolean done;
            volatile boolean exited;
            volatile int code;

            ReadSide(LineQueue queue, boolean isStdout) {
                this.queue = queue;
                this.isStdout = isStdout;
            }
        }

        void close() {
            try {
                stdin.write("exit\n".getBytes(StandardCharsets.UTF_8));
                stdin.flush();
            } catch (IOException ignored) {
            }
            p.destroy();
        }
    }

    static boolean isRootId(String out) {
        if (out == null) return false;
        String s = out.trim();
        return "0".equals(s) || s.startsWith("uid=0 ") || s.startsWith("uid=0(");
    }

    // ------------------------------------------------------------------ JS glue (pure)

    /** JSON/JS string literal (safe for evaluateJavascript). */
    public static String jsString(String s) {
        if (s == null) return "\"\"";
        StringBuilder b = new StringBuilder(s.length() + 16).append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"': b.append("\\\""); break;
                case '\\': b.append("\\\\"); break;
                case '\n': b.append("\\n"); break;
                case '\r': b.append("\\r"); break;
                case '\t': b.append("\\t"); break;
                case '<': b.append("\\u003c"); break;
                case '\u2028': b.append("\\u2028"); break;
                case '\u2029': b.append("\\u2029"); break;
                default:
                    if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
                    else b.append(c);
            }
        }
        return b.append('"').toString();
    }

    public static boolean validCallbackName(String n) {
        return n != null && n.matches("[A-Za-z_$][A-Za-z0-9_$]*");
    }

    /** JS that invokes window[cb](errno, stdout, stderr) through the WebUI bridge. */
    public static String callbackJs(String cb, Result r) {
        return "(function(){var f=window[" + jsString(cb) + "];if(typeof f==='function')f(" + r.code + ","
                + jsString(r.out) + "," + jsString(r.err) + ");})();";
    }
}
