package com.lixkrt.hotspotplus;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Future;
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
 */
public final class RootShell {

    public static final int EACCES = 13;
    public static final String DENIED_MSG =
            "未获得 root 权限：请打开 KernelSU 管理器 →「超级用户」，找到「热点增强」并允许 root，然后回到本应用点「重试」。";

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

    /** Run asynchronously; callback is invoked on a pool thread. */
    public void exec(String cmd, String cwd, Map<String, String> env, Callback cb) {
        pool.execute(() -> cb.onResult(doRun(cmd, cwd, env)));
    }

    /** Blocking helper; never call from a pool callback. */
    public Result run(String cmd) {
        Future<Result> f = pool.submit(() -> doRun(cmd, null, null));
        try {
            return f.get();
        } catch (Exception e) {
            return new Result(1, "", String.valueOf(e), false);
        }
    }

    private Result doRun(String cmd, String cwd, Map<String, String> env) {
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
                    return new Result(1, "", "无法启动 root shell: " + e.getMessage(), false);
                }
            }
            denied = false;
            try {
                return s.run(cmd, cwd, env, 0);
            } catch (WriteFailed e) {
                s.close();
                local.remove();
                if (attempt == 1) return new Result(1, "", "root shell 异常: " + e.getMessage(), false);
            } catch (IOException e) {
                // shell died while the command was running: do NOT re-run it (could toggle twice)
                s.close();
                local.remove();
                return new Result(1, "", "root shell 在执行中退出: " + e.getMessage(), false);
            }
        }
        return new Result(1, "", "unreachable", false);
    }

    // ------------------------------------------------------------------ helpers

    static String sq(String s) {
        return "'" + s.replace("'", "'\\''") + "'";
    }

    static boolean validEnvKey(String k) {
        return k != null && k.matches("[A-Za-z_][A-Za-z0-9_]*");
    }

    /** Shell text sent to the persistent shell for one command. Package-private for tests. */
    static String frame(String cmd, String cwd, Map<String, String> env, String marker) {
        String b64 = Base64.getEncoder().encodeToString(cmd.getBytes(StandardCharsets.UTF_8));
        StringBuilder sb = new StringBuilder(b64.length() + 256);
        sb.append("__hsp_c=$(printf '%s' '").append(b64).append("' | base64 -d)\n");
        sb.append("( ");
        if (cwd != null && !cwd.isEmpty()) sb.append("cd ").append(sq(cwd)).append(" || exit 1; ");
        if (env != null) {
            for (Map.Entry<String, String> e : env.entrySet()) {
                if (validEnvKey(e.getKey())) {
                    sb.append("export ").append(e.getKey()).append('=').append(sq(String.valueOf(e.getValue()))).append("; ");
                }
            }
        }
        sb.append("eval \"$__hsp_c\"\n) </dev/null\n");
        sb.append("__hsp_rc=$?; printf '\\n%s %d\\n' ").append(marker).append(" \"$__hsp_rc\"; printf '\\n%s\\n' ")
                .append(marker).append(" >&2\n");
        return sb.toString();
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
    }

    final class Shell {
        final Process p;
        final OutputStream stdin;
        final LineQueue outQ;
        final LineQueue errQ;

        Shell() throws IOException {
            try {
                p = new ProcessBuilder(suCmd).start();
            } catch (IOException e) {
                // KernelSU: an app without root grant cannot even see/exec "su" (ENOENT/EACCES)
                throw new DeniedException("su: " + e.getMessage());
            }
            stdin = p.getOutputStream();
            outQ = new LineQueue(p.getInputStream(), "su-out");
            errQ = new LineQueue(p.getErrorStream(), "su-err");
            Result r;
            try {
                r = run("id -u", null, null, 60000); // generous: Magisk-style prompts
            } catch (IOException e) {
                close();
                throw new DeniedException("su 已退出 (" + e.getMessage() + ")");
            }
            if (requireUid0 && !"0".equals(r.out.trim())) {
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

        Result run(String cmd, String cwd, Map<String, String> env, long timeoutMs) throws IOException {
            String marker = "__HSP_END_" + UUID.randomUUID().toString().replace("-", "");
            if (!alive()) throw new WriteFailed("shell not running");
            try {
                stdin.write(frame(cmd, cwd, env, marker).getBytes(StandardCharsets.UTF_8));
                stdin.flush();
            } catch (IOException e) {
                throw new WriteFailed(e.getMessage());
            }
            List<String> out = new ArrayList<>();
            int code;
            while (true) {
                String l = outQ.take(timeoutMs);
                if (l.startsWith(marker + " ")) {
                    try {
                        code = Integer.parseInt(l.substring(marker.length() + 1).trim());
                    } catch (NumberFormatException e) {
                        code = 1;
                    }
                    break;
                }
                out.add(l);
            }
            List<String> err = new ArrayList<>();
            while (true) {
                String l = errQ.take(timeoutMs > 0 ? timeoutMs : 0);
                if (l.equals(marker)) break;
                err.add(l);
            }
            return new Result(code, join(out), join(err), false);
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

    /** JS that invokes window[cb](errno, stdout, stderr) exactly like KernelSU's WebUI does. */
    public static String callbackJs(String cb, Result r) {
        return "(function(){var f=window[" + jsString(cb) + "];if(typeof f==='function')f(" + r.code + ","
                + jsString(r.out) + "," + jsString(r.err) + ");})();";
    }
}
