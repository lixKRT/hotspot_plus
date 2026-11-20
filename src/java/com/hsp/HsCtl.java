package com.hsp;

import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;

import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.net.InetAddress;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * hsctl - tiny root helper for the hotspot_plus KernelSU module.
 *
 * Launched via:  CLASSPATH=hsctl.dex app_process /system/bin com.hsp.HsCtl <cmd> [args]
 * Runs as uid 0, so TetheringService permission checks (TETHER_PRIVILEGED / NETWORK_STACK)
 * pass (ActivityManager grants every permission to ROOT_UID/SYSTEM_UID).
 *
 * Everything hidden is accessed by reflection so one dex works on Android 11 .. 16/17 even when
 * AIDL signatures gain/lose parameters. Talks directly to the "tethering" binder service
 * (android.net.ITetheringConnector) - exactly what TetheringManager.startTethering() does.
 *
 * Commands:
 *   start [--static LOCAL/PFX [CLIENT/PFX]] [--pkg NAME] [--timeout SEC] [--no-exempt]
 *   stop  [--pkg NAME] [--timeout SEC]
 *   state                 -> ap_state=<int> ap_state_name=<..>   (IWifiManager.getWifiApEnabledState)
 *   config                -> saved SoftApConfiguration (ssid/passphrase base64, security, band)
 *   probe                 -> prints reflected signatures (for diagnostics)
 *   common: [--no-hapi] skip hidden-API exemption, [--deadline SEC] hard self-kill (default timeout+15)
 * Exit: 0 ok, 1 tethering returned an error, 2 exception / unsupported, 3 timeout waiting result,
 *       4 internal deadline hit (process halted itself so it can never hang the caller)
 *
 * Android 17 (SDK 37) note: ITetheringConnector / TetheringRequestParcel / IIntResultListener AIDL
 * are unchanged vs Android 16 in AOSP android17-release, so the same reflective path applies; every
 * overload actually found is printed as "sig=" so OEM changes show up in the log.
 */
public final class HsCtl {
    static final String LISTENER_DESC = "android.net.IIntResultListener";
    static final int TETHERING_WIFI = 0;
    static final int CONNECTIVITY_SCOPE_GLOBAL = 1;
    static final int REQUEST_TYPE_EXPLICIT = 0;
    static final String VERSION = "0.1.1";

    static final String[] ERRORS = {
        "NO_ERROR", "UNKNOWN_IFACE", "SERVICE_UNAVAIL", "UNSUPPORTED", "UNAVAIL_IFACE",
        "INTERNAL_ERROR", "TETHER_IFACE_ERROR", "UNTETHER_IFACE_ERROR", "ENABLE_FORWARDING_ERROR",
        "DISABLE_FORWARDING_ERROR", "IFACE_CFG_ERROR", "PROVISIONING_FAILED", "DHCPSERVER_ERROR",
        "ENTITLEMENT_UNKNOWN", "NO_CHANGE_TETHERING_PERMISSION", "NO_ACCESS_TETHERING_PERMISSION",
        "UNKNOWN_TYPE", "UNKNOWN_REQUEST", "DUPLICATE_REQUEST", "BLUETOOTH_SERVICE_PENDING",
        "SOFT_AP_CALLBACK_PENDING"
    };

    public static void main(String[] args) {
        int rc;
        try {
            boolean hapi = true;
            int deadline = -1, timeout = 25;
            for (int i = 0; i < args.length; i++) {
                if ("--no-hapi".equals(args[i])) hapi = false;
                else if ("--deadline".equals(args[i]) && i + 1 < args.length) deadline = Integer.parseInt(args[i + 1]);
                else if ("--timeout".equals(args[i]) && i + 1 < args.length) timeout = Integer.parseInt(args[i + 1]);
            }
            startWatchdog(deadline > 0 ? deadline : timeout + 15);
            System.out.println("hsctl_version=" + VERSION + " sdk=" + sdkInt() + " release=" + sysProp("ro.build.version.release"));
            if (hapi) exemptHiddenApi();
            rc = run(args);
        } catch (Throwable t) {
            Throwable c = t;
            while (c.getCause() != null && c != c.getCause()) c = c.getCause();
            System.out.println("error=" + c);
            t.printStackTrace();
            rc = 2;
        }
        System.out.flush();
        System.exit(rc);
    }

    static void startWatchdog(final int sec) {
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                try { Thread.sleep(sec * 1000L); } catch (InterruptedException e) { return; }
                System.out.println("error=deadline " + sec + "s exceeded, halting");
                System.out.flush();
                Runtime.getRuntime().halt(4);
            }
        }, "hsctl-watchdog");
        t.setDaemon(true);
        t.start();
    }

    static int sdkInt() {
        try {
            return Class.forName("android.os.Build$VERSION").getField("SDK_INT").getInt(null);
        } catch (Throwable t) {
            return -1;
        }
    }

    static String sysProp(String k) {
        try {
            return (String) Class.forName("android.os.SystemProperties").getMethod("get", String.class).invoke(null, k);
        } catch (Throwable t) {
            return "?";
        }
    }

    static int run(String[] a) throws Throwable {
        if (a.length == 0) {
            System.out.println("usage: start|stop|state|config|probe");
            return 2;
        }
        String cmd = a[0];
        String pkg = "root";
        int timeout = 25;
        String local = null, client = null;
        boolean exempt = true;
        for (int i = 1; i < a.length; i++) {
            if ("--static".equals(a[i]) && i + 1 < a.length) {
                local = a[++i];
                // Android requires a static client address together with the local
                // address; keep the old two-argument form but derive the placeholder
                // here so callers cannot accidentally leave it unset.
                if (i + 1 < a.length && a[i + 1].indexOf('/') > 0) client = a[++i];
            }
            else if ("--pkg".equals(a[i]) && i + 1 < a.length) { pkg = a[++i]; }
            else if ("--timeout".equals(a[i]) && i + 1 < a.length) { timeout = Integer.parseInt(a[++i]); }
            else if ("--no-exempt".equals(a[i])) { exempt = false; }
            else if ("--deadline".equals(a[i])) { i++; }
        }
        if ("start".equals(cmd)) return start(pkg, local, client, exempt, timeout);
        if ("stop".equals(cmd)) return stop(pkg, timeout);
        if ("state".equals(cmd)) return state();
        if ("config".equals(cmd)) return config();
        if ("probe".equals(cmd)) return probe();
        System.out.println("error=unknown command " + cmd);
        return 2;
    }

    // ---------------------------------------------------------------- binder plumbing

    static IBinder getService(String name) throws Throwable {
        Class<?> sm = Class.forName("android.os.ServiceManager");
        Object b = sm.getMethod("getService", String.class).invoke(null, name);
        if (b == null) throw new IllegalStateException("service '" + name + "' not found");
        return (IBinder) b;
    }

    static Object asInterface(String stubClass, IBinder b) throws Throwable {
        Class<?> stub = Class.forName(stubClass);
        return stub.getMethod("asInterface", IBinder.class).invoke(null, b);
    }

    /**
     * Pick an overload: prefer one whose parameter type simple-names equal {@code prefer}
     * (the AOSP 11..17 signature), else the one with most parameters. Logs every overload seen.
     */
    static Method findMethod(Object target, String name, String... prefer) {
        Method best = null, exact = null;
        for (Method m : target.getClass().getMethods()) {
            if (!m.getName().equals(name)) continue;
            System.out.println("sig=" + m.toGenericString());
            Class<?>[] p = m.getParameterTypes();
            if (prefer.length > 0 && p.length == prefer.length) {
                boolean ok = true;
                for (int i = 0; i < p.length; i++) if (!p[i].getSimpleName().equals(prefer[i])) { ok = false; break; }
                if (ok) exact = m;
            }
            if (best == null || p.length > best.getParameterTypes().length) best = m;
        }
        return exact != null ? exact : best;
    }

    /** Local Binder that receives IIntResultListener.onResult(int) (oneway, txn code 1). */
    static final class ResultBinder extends Binder {
        final CountDownLatch latch = new CountDownLatch(1);
        volatile int result = Integer.MIN_VALUE;

        ResultBinder() { attachInterface(null, LISTENER_DESC); }

        @Override
        protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) {
            if (code == 1) { // FIRST_CALL_TRANSACTION == onResult
                int r;
                try {
                    data.enforceInterface(LISTENER_DESC);
                    r = data.readInt();
                } catch (Throwable t) {
                    // payload is <interface token header><int>; the int is always the last 4 bytes
                    data.setDataPosition(data.dataSize() - 4);
                    r = data.readInt();
                }
                result = r;
                latch.countDown();
                return true;
            }
            try {
                return super.onTransact(code, data, reply, flags);
            } catch (Throwable t) {
                return false;
            }
        }
    }

    static Object makeListener(final ResultBinder rb) throws Throwable {
        Class<?> lis = Class.forName(LISTENER_DESC);
        try {
            return makeProxyListener(lis, rb);
        } catch (Throwable t) {
            // fallback: let the AIDL stub wrap our Binder (queryLocalInterface returns null -> Stub.Proxy)
            System.out.println("warn=proxy listener failed (" + t + "), using Stub.asInterface");
            return asInterface(LISTENER_DESC + "$Stub", rb);
        }
    }

    static Object makeProxyListener(Class<?> lis, final ResultBinder rb) {
        return Proxy.newProxyInstance(HsCtl.class.getClassLoader(), new Class<?>[] {lis},
                new InvocationHandler() {
                    @Override
                    public Object invoke(Object proxy, Method m, Object[] args) {
                        String n = m.getName();
                        if ("asBinder".equals(n)) return rb;
                        if ("onResult".equals(n)) { rb.result = (Integer) args[0]; rb.latch.countDown(); return null; }
                        if ("hashCode".equals(n)) return System.identityHashCode(proxy);
                        if ("equals".equals(n)) return proxy == args[0];
                        if ("toString".equals(n)) return "HsCtlListener";
                        return null;
                    }
                });
    }

    /** Fill a reflected method's arguments by type: request parcel, int type, Strings, listener. */
    static Object[] buildArgs(Method m, Object parcel, int type, String pkg, Object listener) {
        Class<?>[] p = m.getParameterTypes();
        Object[] out = new Object[p.length];
        int strings = 0;
        for (int i = 0; i < p.length; i++) {
            Class<?> c = p[i];
            String cn = c.getName();
            if (c == int.class) out[i] = type;
            else if (c == boolean.class) out[i] = Boolean.FALSE;
            else if (c == String.class) out[i] = (strings++ == 0) ? pkg : null; // callerPkg, attributionTag
            else if (cn.endsWith("TetheringRequestParcel")) out[i] = parcel;
            else if (cn.endsWith("TetheringRequest") && parcel != null) out[i] = toRequest(parcel);
            else if (cn.endsWith("IIntResultListener")) out[i] = listener;
            else out[i] = null;
        }
        return out;
    }

    static int await(ResultBinder rb, int timeout, String what) throws InterruptedException {
        if (!rb.latch.await(timeout, TimeUnit.SECONDS)) {
            System.out.println(what + "_result=timeout");
            return 3;
        }
        int r = rb.result;
        String name = (r >= 0 && r < ERRORS.length) ? ERRORS[r] : String.valueOf(r);
        System.out.println(what + "_result=" + r + " (" + name + ")");
        return r == 0 ? 0 : 1;
    }

    // ---------------------------------------------------------------- commands

    static Object newLinkAddress(String s) throws Throwable {
        Class<?> la = Class.forName("android.net.LinkAddress");
        try {
            Constructor<?> c = la.getDeclaredConstructor(String.class);
            c.setAccessible(true);
            return c.newInstance(s);
        } catch (NoSuchMethodException e) {
            int slash = s.indexOf('/');
            Constructor<?> c = la.getDeclaredConstructor(InetAddress.class, int.class);
            c.setAccessible(true);
            return c.newInstance(InetAddress.getByName(s.substring(0, slash)),
                    Integer.parseInt(s.substring(slash + 1)));
        }
    }

    static void setField(Object o, String name, Object v) {
        try {
            Field f = o.getClass().getField(name);
            f.set(o, v);
        } catch (NoSuchFieldException e) {
            // field not present on this Android version - fine
        } catch (Throwable t) {
            System.out.println("warn=cannot set " + name + ": " + t);
        }
    }

    /** TetheringRequest(TetheringRequestParcel) - hidden ctor; needed for stopTetheringRequest (SDK 36+). */
    static Object toRequest(Object parcel) {
        try {
            Class<?> rc = Class.forName("android.net.TetheringManager$TetheringRequest");
            Constructor<?> c = rc.getDeclaredConstructor(parcel.getClass());
            c.setAccessible(true);
            return c.newInstance(parcel);
        } catch (Throwable t) {
            System.out.println("warn=cannot build TetheringRequest: " + t);
            return null;
        }
    }

    static Object newWifiParcel(boolean exempt) throws Throwable { return newWifiParcel(exempt, null); }

    /**
     * Fields seen on Android 17 / HyperOS OS4 (probe): connectivityScope, exemptFromEntitlementCheck,
     * interfaceName, localIPv4Address, packageName, requestType, showProvisioningUi, softApConfig,
     * staticClientAddress, tetheringType, uid. TetheringService overwrites uid/packageName with the
     * binder caller anyway; interfaceName must stay null (non-null => privileged-only path).
     */
    static Object newWifiParcel(boolean exempt, String pkg) throws Throwable {
        Class<?> pc = Class.forName("android.net.TetheringRequestParcel");
        Object parcel = pc.getDeclaredConstructor().newInstance();
        setField(parcel, "tetheringType", TETHERING_WIFI);
        setField(parcel, "requestType", REQUEST_TYPE_EXPLICIT);
        setField(parcel, "connectivityScope", CONNECTIVITY_SCOPE_GLOBAL);
        setField(parcel, "exemptFromEntitlementCheck", exempt);
        setField(parcel, "showProvisioningUi", Boolean.FALSE);
        setField(parcel, "uid", -1);
        setField(parcel, "softApConfig", null);
        setField(parcel, "interfaceName", null);
        if (pkg != null) setField(parcel, "packageName", pkg);
        return parcel;
    }

    static int start(String pkg, String local, String client, boolean exempt, int timeout) throws Throwable {
        Object conn = asInterface("android.net.ITetheringConnector$Stub", getService("tethering"));
        Object parcel = newWifiParcel(exempt, pkg); // softApConfig null => Wi-Fi uses the user's saved hotspot config
        if (local != null) {
            if (client == null) client = placeholder(local);
            setField(parcel, "localIPv4Address", newLinkAddress(local));
            setField(parcel, "staticClientAddress", newLinkAddress(client));
            System.out.println("static_local=" + local + " static_client=" + client);
        }
        Method m = findMethod(conn, "startTethering", "TetheringRequestParcel", "String", "String", "IIntResultListener");
        if (m == null) throw new NoSuchMethodException("ITetheringConnector.startTethering");
        ResultBinder rb = new ResultBinder();
        Object listener = makeListener(rb);
        System.out.println("calling=" + m);
        m.invoke(conn, buildArgs(m, parcel, TETHERING_WIFI, pkg, listener));
        return await(rb, timeout, "start");
    }

    static int stop(String pkg, int timeout) throws Throwable {
        Object conn = asInterface("android.net.ITetheringConnector$Stub", getService("tethering"));
        Method m = findMethod(conn, "stopTethering", "int", "String", "String", "IIntResultListener");
        int rc = 2;
        if (m != null) {
            try {
                ResultBinder rb = new ResultBinder();
                Object listener = makeListener(rb);
                System.out.println("calling=" + m);
                m.invoke(conn, buildArgs(m, null, TETHERING_WIFI, pkg, listener));
                rc = await(rb, timeout, "stop");
            } catch (Throwable t) {
                System.out.println("warn=stopTethering failed: " + t);
            }
        }
        if (rc == 0 || sdkInt() < 36) {
            if (m == null) throw new NoSuchMethodException("ITetheringConnector.stopTethering");
            return rc;
        }
        // stopTethering(type) is preferred: it stops Wi-Fi tethering no matter who started it (Settings,
        // QS tile, us). SDK 36+ fallback: request-based stop (fuzzy-matched against active requests of
        // the SAME uid, so it only stops a hotspot that hsctl itself started).
        Method m2 = findMethod(conn, "stopTetheringRequest", "TetheringRequest", "String", "String", "IIntResultListener");
        if (m2 == null) return rc;
        ResultBinder rb2 = new ResultBinder();
        Object l2 = makeListener(rb2);
        System.out.println("calling=" + m2);
        m2.invoke(conn, buildArgs(m2, newWifiParcel(false, pkg), TETHERING_WIFI, pkg, l2));
        return await(rb2, timeout, "stop_request");
    }

    /** Last usable host address of the local prefix; Android's static DHCP needs one. */
    static String placeholder(String local) {
        int slash = local.indexOf('/');
        if (slash < 0) return local;
        String ip = local.substring(0, slash);
        int prefix = Integer.parseInt(local.substring(slash + 1));
        String[] p = ip.split("\\.");
        if (p.length != 4 || prefix < 1 || prefix > 30) throw new IllegalArgumentException("bad static local: " + local);
        long v = 0;
        for (String s : p) v = (v << 8) | Integer.parseInt(s);
        long host = (1L << (32 - prefix)) - 2;
        v = (v & ~((1L << (32 - prefix)) - 1)) | host;
        return ((v >> 24) & 255) + "." + ((v >> 16) & 255) + "." + ((v >> 8) & 255) + "." + (v & 255);
    }

    static Object wifi() throws Throwable {
        return asInterface("android.net.wifi.IWifiManager$Stub", getService("wifi"));
    }

    static int state() throws Throwable {
        Object w = wifi();
        int s = (Integer) w.getClass().getMethod("getWifiApEnabledState").invoke(w);
        String[] names = {"DISABLING", "DISABLED", "ENABLING", "ENABLED", "FAILED"};
        String n = (s >= 10 && s <= 14) ? names[s - 10] : "UNKNOWN";
        System.out.println("ap_state=" + s);
        System.out.println("ap_state_name=" + n);
        return 0;
    }

    static String b64(String s) {
        if (s == null) return "";
        try {
            return java.util.Base64.getEncoder().encodeToString(s.getBytes("UTF-8"));
        } catch (Throwable t) {
            return "";
        }
    }

    static Object call(Object o, String name) {
        try {
            return o.getClass().getMethod(name).invoke(o);
        } catch (Throwable t) {
            return null;
        }
    }

    static int config() throws Throwable {
        Object w = wifi();
        Object cfg = w.getClass().getMethod("getSoftApConfiguration").invoke(w);
        if (cfg == null) { System.out.println("error=null SoftApConfiguration"); return 2; }
        Object ssid = call(cfg, "getSsid");
        if (ssid == null) {
            Object ws = call(cfg, "getWifiSsid");
            if (ws != null) {
                String s = ws.toString();
                if (s.length() >= 2 && s.startsWith("\"") && s.endsWith("\"")) s = s.substring(1, s.length() - 1);
                ssid = s;
            }
        }
        System.out.println("ssid_b64=" + b64(ssid == null ? null : ssid.toString()));
        Object pass = call(cfg, "getPassphrase");
        System.out.println("pass_b64=" + b64(pass == null ? null : pass.toString()));
        Object sec = call(cfg, "getSecurityType");
        System.out.println("security=" + sec); // 0 open,1 wpa2,2 wpa3_transition,3 wpa3,4 wpa3_owe_transition,5 owe
        Object band = call(cfg, "getBand");
        System.out.println("band=" + band);     // bitmask: 1=2.4G 2=5G 4=6G 8=60G
        Object hidden = call(cfg, "isHiddenSsid");
        System.out.println("hidden=" + hidden);
        return 0;
    }

    static int probe() {
        System.out.println("sdk=" + sdkInt());
        try {
            Object conn = asInterface("android.net.ITetheringConnector$Stub", getService("tethering"));
            System.out.println("tethering_binder=ok " + conn.getClass().getName());
            for (Method m : conn.getClass().getDeclaredMethods()) {
                System.out.println("method=" + m.toGenericString());
            }
        } catch (Throwable t) { System.out.println("tethering_binder=fail " + t); }
        try {
            Class<?> pc = Class.forName("android.net.TetheringRequestParcel");
            for (Field f : pc.getFields()) System.out.println("parcel_field=" + f.getType().getSimpleName() + " " + f.getName());
        } catch (Throwable t) { System.out.println("parcel=fail " + t); }
        try {
            Class<?> rc = Class.forName("android.net.TetheringManager$TetheringRequest");
            for (Constructor<?> c : rc.getDeclaredConstructors()) System.out.println("request_ctor=" + c.toGenericString());
        } catch (Throwable t) { System.out.println("request_ctor=fail " + t); }
        try {
            Class.forName(LISTENER_DESC);
            System.out.println("listener_iface=ok");
        } catch (Throwable t) { System.out.println("listener_iface=fail " + t); }
        try {
            Object w = wifi();
            for (Method m : w.getClass().getDeclaredMethods()) {
                String n = m.getName();
                if (n.contains("SoftAp") || n.contains("WifiAp") || n.contains("Tether"))
                    System.out.println("wifi_method=" + m.toGenericString());
            }
            state();
        } catch (Throwable t) { System.out.println("wifi_state=fail " + t); }
        return 0;
    }

    /** Best effort; app_process normally has no hidden-API enforcement anyway. */
    static void exemptHiddenApi() {
        try {
            Method forName = Class.class.getDeclaredMethod("forName", String.class);
            Method getDeclaredMethod = Class.class.getDeclaredMethod("getDeclaredMethod", String.class, Class[].class);
            Class<?> vmr = (Class<?>) forName.invoke(null, "dalvik.system.VMRuntime");
            Method getRuntime = (Method) getDeclaredMethod.invoke(vmr, "getRuntime", null);
            Method setEx = (Method) getDeclaredMethod.invoke(vmr, "setHiddenApiExemptions", new Object[] {new Class<?>[] {String[].class}});
            setEx.invoke(getRuntime.invoke(null), new Object[] {new String[] {"L"}});
        } catch (Throwable ignored) {
        }
    }
}
