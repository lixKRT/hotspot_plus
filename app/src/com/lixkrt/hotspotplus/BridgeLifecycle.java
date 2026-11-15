package com.lixkrt.hotspotplus;

/**
 * Deterministic lifecycle for the trusted WebUI JavaScript bridges. A bridge is installed only
 * after its trusted local document finishes loading. Within the trusted origin that binding is
 * never replaced, so reloads keep the same object id; leaving the trusted origin or destroying the
 * host removes it. Page callbacks never add or remove it mid-document.
 */
final class BridgeLifecycle {
    enum Action { NONE, INSTALL, REMOVE }

    private boolean installed;
    private boolean pending;
    private String url;
    private boolean trusted;

    boolean installed() {
        return installed;
    }

    String url() {
        return url;
    }

    boolean trusted() {
        return trusted;
    }

    /** True when the current trusted document finished loading but has no bridge yet. */
    boolean needsInstall() {
        return pending && trusted;
    }

    /** An explicit trusted document load: bind once, then keep that object across reloads. */
    Action loadingDocument(String target) {
        boolean local = WebPolicy.classifyDocument(target);
        if (!local) return navigating(target);
        url = target;
        trusted = true;
        if (!installed) pending = true;
        return Action.NONE;
    }

    /** A page callback says a trusted URL is starting; never disturb an existing binding. */
    Action pageStarted(String target) {
        boolean local = WebPolicy.classifyDocument(target);
        if (!local) return navigating(target);
        url = target;
        trusted = true;
        if (!installed) pending = true;
        return Action.NONE;
    }

    /** Navigation/untrusted content: drop the bridge before any document can call it. */
    Action navigating(String target) {
        if (target != null && target.equals(url)) return Action.NONE;
        url = target;
        trusted = WebPolicy.classifyDocument(target);
        pending = false;
        if (!installed) return Action.NONE;
        installed = false;
        return Action.REMOVE;
    }

    /** Page finished: the trusted target document is the one this state machine is tracking. */
    boolean accepting(String finished) {
        return trusted && finished != null && finished.equals(url);
    }

    Action destroy() {
        url = null;
        trusted = false;
        pending = false;
        if (!installed) return Action.NONE;
        installed = false;
        return Action.REMOVE;
    }

    /** Called after the bridge is installed for the finished trusted document. */
    void markInstalled() {
        pending = false;
        installed = true;
    }
}
