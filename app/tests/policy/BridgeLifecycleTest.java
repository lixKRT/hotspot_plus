package com.lixkrt.hotspotplus;

/** Regression for deterministic bridge binding across reloads and navigation. */
public final class BridgeLifecycleTest {
    private static int failures;

    public static void main(String[] args) {
        String local = WebPolicy.LOCAL_ORIGIN;
        BridgeLifecycle b = new BridgeLifecycle();
        check("starts uninstalled", !b.installed());
        check("load defers install", b.loadingDocument(local) == BridgeLifecycle.Action.NONE);
        check("not installed while loading", !b.installed() && b.needsInstall());
        check("page start keeps deferral", b.pageStarted(local) == BridgeLifecycle.Action.NONE);
        check("finished document accepted", b.accepting(local));
        b.markInstalled();
        check("installed after finish", b.installed() && !b.needsInstall());
        check("reload removes old binding", b.loadingDocument(local) == BridgeLifecycle.Action.REMOVE);
        check("reload deferred", !b.installed() && b.needsInstall());
        b.markInstalled();
        check("external navigation removes", b.navigating("https://example.com/") == BridgeLifecycle.Action.REMOVE);
        check("external document rejected", !b.accepting("https://example.com/"));
        check("returning to local defers", b.loadingDocument(local) == BridgeLifecycle.Action.NONE);
        b.markInstalled();
        check("returned document accepted", b.accepting(local));
        check("destroy removes", b.destroy() == BridgeLifecycle.Action.REMOVE);
        check("destroyed has no binding", !b.installed() && b.destroy() == BridgeLifecycle.Action.NONE);
        check("fresh load after destroy defers", b.loadingDocument(local) == BridgeLifecycle.Action.NONE);

        BridgeLifecycle wrong = new BridgeLifecycle();
        wrong.loadingDocument(local);
        check("mismatched finish rejected", !wrong.accepting(local + "other"));

        BridgeLifecycle reload = new BridgeLifecycle();
        check("reload defers target document", reload.loadingDocument(local) == BridgeLifecycle.Action.NONE);
        check("page start after reload defers", reload.pageStarted(local) == BridgeLifecycle.Action.NONE);
        BridgeLifecycle external = new BridgeLifecycle();
        external.loadingDocument(local);
        external.markInstalled();
        check("external start removes bridge", external.pageStarted("https://example.com/") == BridgeLifecycle.Action.REMOVE);
        check("external document rejected", !external.accepting("https://example.com/"));
        System.out.println("bridge lifecycle: " + (failures == 0 ? "ok" : failures + " failed"));
        if (failures != 0) System.exit(1);
    }

    private static void check(String name, boolean ok) {
        if (!ok) {
            failures++;
            System.err.println("FAIL " + name);
        }
    }
}
