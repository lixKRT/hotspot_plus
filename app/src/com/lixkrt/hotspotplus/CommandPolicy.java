package com.lixkrt.hotspotplus;

import java.util.regex.Pattern;

/**
 * The WebUI may only invoke the fixed module CLI surface. This is deliberately narrower than a
 * general shell: the page is trusted, but unrelated content or injected script must not turn the
 * long-lived root bridge into an arbitrary root shell.
 */
public final class CommandPolicy {
    private static final Pattern SIMPLE = Pattern.compile(
            "^\\s*(?:status(?:\\s+--json)?|clients(?:\\s+--json)?|config(?:\\s+--json)?|toggle|on|off|restart|"
                    + "apply|unstick|log(?:\\s+\\d{1,4})?|diag|daemon\\s+restart)\\s*$");
    private static final String VALUE = "(?:'[^'\\r\\n]*'|\"[^\"\\r\\n]*\"|[^\\s;|&`$<>()\\\\]+)";
    private static final Pattern SET_KNOWN = Pattern.compile(
            "^\\s*set(?:\\s+(?:FIXED_GATEWAY|PREFIX|GATEWAY|DHCP_ENABLE|DHCP_START|DHCP_END|LEASE_TIME|"
                    + "ENFORCE_GATEWAY|AUTO_START|AP_IFACE|METERED|DNS|POLL_INTERVAL)=" + VALUE + ")+\\s*$");
    private static final Pattern LEASE_IMPORT = Pattern.compile(
            "^\\s*lease\\s+import\\s+[A-Za-z0-9+/=]+\\s*$");

    private CommandPolicy() {}

    public static boolean allowed(String command, boolean trustedDocument) {
        if (!trustedDocument || command == null) return false;
        return SET_KNOWN.matcher(command).matches()
                || LEASE_IMPORT.matcher(command).matches()
                || SIMPLE.matcher(command).matches();
    }
}
