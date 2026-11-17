package com.lixkrt.hotspotplus;

/** Regression for deterministic bridge binding across reloads and navigation. */
public final class BridgeLifecycleTest {
    private static int failures;

    public static void main(String[] args) {
        String local = WebPolicy.LOCAL_ORIGIN;
        BridgeLifecycle b = new BridgeLifecycle();
        check("starts uninstalled", !b.installed());
        check("load installs before document", b.loadingDocument(local) == BridgeLifecycle.Action.INSTALL);
        check("installed before loading", b.installed() && !b.needsInstall());
        check("page start keeps binding", b.pageStarted(local) == BridgeLifecycle.Action.NONE);
        check("finished document accepted", b.accepting(local));
        check("reload keeps binding", b.loadingDocument(local) == BridgeLifecycle.Action.NONE);
        check("reload still bound", b.installed() && !b.needsInstall());
        check("page start keeps binding", b.pageStarted(local) == BridgeLifecycle.Action.NONE);
        check("page start still bound", b.installed());
        check("external navigation removes", b.navigating("https://example.com/") == BridgeLifecycle.Action.REMOVE);
        check("external document rejected", !b.accepting("https://example.com/"));
        check("returning to local reinstalls", b.loadingDocument(local) == BridgeLifecycle.Action.INSTALL && b.installed());
        check("returned document accepted", b.accepting(local));
        check("destroy removes", b.destroy() == BridgeLifecycle.Action.REMOVE);
        check("destroyed has no binding", !b.installed() && b.destroy() == BridgeLifecycle.Action.NONE);
        check("fresh load after destroy installs", b.loadingDocument(local) == BridgeLifecycle.Action.INSTALL);

        BridgeLifecycle wrong = new BridgeLifecycle();
        wrong.loadingDocument(local);
        check("mismatched finish rejected", !wrong.accepting(local + "other"));

        BridgeLifecycle reload = new BridgeLifecycle();
        check("reload installs target document", reload.loadingDocument(local) == BridgeLifecycle.Action.INSTALL);
        check("page start after reload keeps binding", reload.pageStarted(local) == BridgeLifecycle.Action.NONE
                && reload.installed());
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
