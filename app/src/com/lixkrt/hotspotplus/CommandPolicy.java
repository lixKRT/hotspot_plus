package com.lixkrt.hotspotplus;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Strict parser for the WebUI's fixed hsp command surface.
 *
 * <p>Commands are parsed as argv, never as shell text. A token may be wholly single- or
 * double-quoted, but escapes, substitutions, control characters and unquoted metacharacters are
 * rejected before any root operation.</p>
 */
public final class CommandPolicy {
    public static final String CLI = "/data/adb/modules/hotspot_plus/bin/hsp";
    public static final String IMPORT_FILE = BridgeCommands.LEASE_IMPORT;

    private static final Pattern IPV4 = Pattern.compile(
            "(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)(?:\\.(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)){3}");
    private static final Pattern MAC = Pattern.compile("(?:[0-9a-f]{2}:){5}[0-9a-f]{2}");
    private static final Pattern REMARK = Pattern.compile("[\\p{L}\\p{N} ._()\\-]{0,64}");
    private static final Set<String> SET_KEYS;

    static {
        Set<String> keys = new LinkedHashSet<>();
        Collections.addAll(keys, "FIXED_GATEWAY", "PREFIX", "GATEWAY", "DHCP_ENABLE", "DHCP_START",
                "DHCP_END", "LEASE_TIME", "ENFORCE_GATEWAY", "AUTO_START", "AP_IFACE", "METERED",
                "DNS", "POLL_INTERVAL");
        SET_KEYS = Collections.unmodifiableSet(keys);
    }

    private CommandPolicy() {}

    /** Compatibility helper used by tests and callers that only need an allow/deny decision. */
    public static boolean allowed(String command, boolean trustedDocument) {
        return trustedDocument && parse(command) != null;
    }

    /** Strictly parse and validate one bridge command, or return null if it is not allowed. */
    public static List<String> parse(String command) {
        List<String> words = tokenize(command);
        if (words == null || words.isEmpty()) return null;

        List<String> out = new ArrayList<>();
        int i = 0;
        if (i >= words.size() || !CLI.equals(words.get(i))) return null;
        i++;
        out.add(CLI);
        if (i >= words.size()) return null;
        String sub = words.get(i++);
        if (!allowedSubcommand(sub, words, i)) return null;
        out.add(sub);
        for (; i < words.size(); i++) out.add(words.get(i));
        return out;
    }

    private static boolean allowedSubcommand(String sub, List<String> words, int i) {
        int n = words.size();
        switch (sub) {
            case "status":
            case "clients":
                return i == n || (i + 1 == n && "--json".equals(words.get(i)));
            case "config":
                return i == n || (i + 1 == n && "--json".equals(words.get(i)));
            case "toggle":
            case "on":
            case "off":
            case "restart":
            case "apply":
            case "unstick":
            case "diag":
                return i == n;
            case "log":
                return i == n || (i + 1 == n && words.get(i).matches("\\d{1,4}"));
            case "daemon":
                return i + 1 == n && "restart".equals(words.get(i));
            case "set":
                return validSet(words.subList(i, n));
            case "lease":
                return validLease(words.subList(i, n));
            default:
                return false;
        }
    }

    private static boolean validSet(List<String> args) {
        if (args.isEmpty()) return false;
        for (String arg : args) {
            int eq = arg.indexOf('=');
            if (eq <= 0 || eq != arg.lastIndexOf('=')) return false;
            String key = arg.substring(0, eq);
            String value = arg.substring(eq + 1);
            if (!SET_KEYS.contains(key)) return false;
            switch (key) {
                case "FIXED_GATEWAY":
                case "DHCP_ENABLE":
                case "ENFORCE_GATEWAY":
                case "AUTO_START":
                case "METERED":
                    if (!"0".equals(value) && !"1".equals(value)) return false;
                    break;
                case "GATEWAY":
                case "DHCP_START":
                case "DHCP_END":
                    if (!IPV4.matcher(value).matches()) return false;
                    break;
                case "PREFIX":
                    if (!value.matches("1[6-9]|2[0-8]")) return false;
                    break;
                case "LEASE_TIME":
                    if (!value.matches("\\d+") || Long.parseLong(value) < 120) return false;
                    break;
                case "POLL_INTERVAL":
                    if (!value.matches("[1-9]|[1-5][0-9]|60")) return false;
                    break;
                case "DNS":
                    if (!value.isEmpty() && !allIpv4(value.split(","))) return false;
                    break;
                case "AP_IFACE":
                    if (!value.matches("[A-Za-z0-9_.-]{0,15}")) return false;
                    break;
                default:
                    return false;
            }
        }
        return true;
    }

    private static boolean validLease(List<String> args) {
        if (args.isEmpty()) return false;
        String op = args.get(0);
        if ("list".equals(op)) return args.size() == 1;
        if ("add".equals(op)) {
            return (args.size() == 3 || args.size() == 4) && validMac(args.get(1))
                    && IPV4.matcher(args.get(2)).matches()
                    && (args.size() == 3 || validRemark(args.get(3)));
        }
        if ("del".equals(op)) return args.size() == 2 && validMac(args.get(1));
        if ("import-file".equals(op)) {
            return args.size() == 2 && IMPORT_FILE.equals(args.get(1));
        }
        if ("stage".equals(op)) {
            if (args.size() == 2 && IMPORT_FILE.equals(args.get(1))) return true;
            return args.size() == 3 && IMPORT_FILE.equals(args.get(1))
                    && args.get(2).startsWith("import=") && decodeImport(args.get(2).substring(7)) != null;
        }
        if (!"import".equals(op) || args.size() < 2) return false;
        Set<String> macs = new LinkedHashSet<>();
        for (int i = 1; i < args.size(); i++) {
            String text = decodeImport(args.get(i));
            if (text == null) return false;
            for (String line : text.substring(0, text.length() - 1).split("\n", -1)) {
                if (line.isEmpty()) return false;
                String[] fields = line.split(" ", 3);
                if (fields.length < 2 || !validMac(fields[0])
                        || !IPV4.matcher(fields[1]).matches()) return false;
                if (fields.length == 3 && !validRemark(fields[2])) return false;
                if (!macs.add(fields[0])) return false;
            }
        }
        return true;
    }

    /** Decode a canonical import chunk, or return null. */
    public static String decodeImport(String encoded) {
        if (encoded == null || !encoded.matches("[A-Za-z0-9+/]+={0,2}")) return null;
        String text;
        try {
            text = new String(Base64.getDecoder().decode(encoded), StandardCharsets.UTF_8);
        } catch (IllegalArgumentException e) {
            return null;
        }
        if (text.isEmpty() || text.length() > 16384 || text.indexOf('\0') >= 0
                || !text.endsWith("\n")) return null;
        return text;
    }

    private static boolean allIpv4(String[] values) {
        for (String value : values) if (!IPV4.matcher(value).matches()) return false;
        return true;
    }

    private static boolean validMac(String value) {
        return MAC.matcher(value).matches();
    }

    private static boolean validRemark(String value) {
        return REMARK.matcher(value).matches();
    }

    /** Tokenize without interpreting shell syntax. Return null on any unsafe character. */
    private static List<String> tokenize(String command) {
        if (command == null) return null;
        List<String> out = new ArrayList<>();
        int i = 0, n = command.length();
        while (i < n) {
            char c = command.charAt(i);
            if (c == ' ') {
                i++;
                continue;
            }
            StringBuilder token = new StringBuilder();
            if (c == '\'' || c == '"') {
                char quote = c;
                i++;
                int end = command.indexOf(quote, i);
                if (end < 0) return null;
                token.append(command, i, end);
                i = end + 1;
                if (i < n && command.charAt(i) != ' ') return null;
            } else {
                while (i < n && command.charAt(i) != ' ') {
                    char ch = command.charAt(i++);
                    if (ch == '\'' || ch == '"' || ch == '\\' || isShellMeta(ch)) return null;
                    token.append(ch);
                }
            }
            if (token.length() == 0 || !safeToken(token.toString())) return null;
            out.add(token.toString());
        }
        return out;
    }

    private static boolean safeToken(String token) {
        for (int i = 0; i < token.length(); i++) {
            char c = token.charAt(i);
            if (c < 0x20 || c == 0x7f || isShellMeta(c)) return false;
        }
        return true;
    }

    private static boolean isShellMeta(char c) {
        return ";|&`$<>()\\\"".indexOf(c) >= 0;
    }
}
