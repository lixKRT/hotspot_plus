package com.hsp.probe;

import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;

import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Read-only Tethering callback probe. Run as uid 0 under app_process.
 *
 * It registers ITetheringEventCallback and waits for the immediate
 * onTetheringSupported callback. No hotspot or tethering state is changed.
 */
public final class CallbackProbe {
    private static final String CONNECTOR = "android.net.ITetheringConnector";
    private static final String CALLBACK = "android.net.ITetheringEventCallback";
    private static final long TIMEOUT_MS = 5000;

    public static void main(String[] args) {
        int rc = 2;
        try {
            rc = run();
        } catch (Throwable t) {
            System.out.println("callback_error=" + t.getClass().getSimpleName());
            rc = 2;
        }
        System.out.flush();
        System.exit(rc);
    }

    private static int run() throws Throwable {
        IBinder service = getService();
        if (service == null) {
            System.out.println("callback_registration=FAIL reason=tethering service missing");
            return 1;
        }
        Class<?> callbackClass = Class.forName(CALLBACK);
        Callback callback = new Callback();
        Object proxy = Proxy.newProxyInstance(
                CallbackProbe.class.getClassLoader(),
                new Class<?>[] {callbackClass},
                callback);
        Object connector = Class.forName(CONNECTOR + "$Stub")
                .getMethod("asInterface", IBinder.class)
                .invoke(null, service);
        Method register = connector.getClass().getMethod(
                "registerTetheringEventCallback", callbackClass, String.class);
        System.out.println("callback_interface=ok");
        register.invoke(connector, proxy, "root");
        System.out.println("event_callback_registration=PASS");
        List<String> names = new ArrayList<>();
        for (Method method : callbackClass.getMethods()) {
            if (!names.contains(method.getName())) names.add(method.getName());
        }
        Collections.sort(names);
        StringBuilder joined = new StringBuilder();
        for (String name : names) {
            if (joined.length() > 0) joined.append(",");
            joined.append(name);
        }
        System.out.println("event_callback_methods=" + joined);

        ResultBinder result = new ResultBinder();
        Class<?> resultClass = Class.forName("android.net.IIntResultListener");
        Object resultListener = Proxy.newProxyInstance(
                CallbackProbe.class.getClassLoader(),
                new Class<?>[] {resultClass},
                new ResultListener(result));
        Method supportedMethod = connector.getClass()
                .getMethod("isTetheringSupported", String.class, String.class, resultClass);
        supportedMethod.invoke(connector, "root", null, resultListener);
        if (result.latch.await(TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            System.out.println("binder_callback=PASS isTetheringSupported_result=" + result.value);
        } else {
            System.out.println("binder_callback=UNVERIFIED reason=timeout");
        }
        unregister(connector, proxy, callbackClass);
        return result.latch.getCount() == 0 ? 0 : 1;
    }

    private static IBinder getService() throws Throwable {
        Class<?> sm = Class.forName("android.os.ServiceManager");
        return (IBinder) sm.getMethod("getService", String.class).invoke(null, "tethering");
    }

    private static void unregister(Object connector, Object proxy, Class<?> callbackClass) {
        try {
            connector.getClass()
                    .getMethod("unregisterTetheringEventCallback", callbackClass, String.class)
                    .invoke(connector, proxy, "root");
            System.out.println("callback_unregister=PASS");
        } catch (Throwable t) {
            System.out.println("callback_unregister=FAIL");
        }
    }

    private static final class Callback implements InvocationHandler {
        final CountDownLatch immediate = new CountDownLatch(1);
        volatile boolean supported;

        @Override
        public Object invoke(Object proxy, Method method, Object[] args) {
            String name = method.getName();
            if ("asBinder".equals(name)) {
                return new Binder();
            }
            if ("onTetheringSupported".equals(name)) {
                supported = args != null && args.length > 0 && Boolean.TRUE.equals(args[0]);
                System.out.println("callback_onTetheringSupported=received");
                immediate.countDown();
                return null;
            }
            if ("onError".equals(name)) {
                System.out.println("callback_error=onError");
                return null;
            }
            if ("hashCode".equals(name)) {
                return System.identityHashCode(proxy);
            }
            if ("equals".equals(name)) {
                return proxy == (args == null ? null : args[0]);
            }
            if ("toString".equals(name)) {
                return "HspCallbackProbe";
            }
            return defaultValue(method.getReturnType());
        }

        private static Object defaultValue(Class<?> type) {
            if (!type.isPrimitive()) return null;
            if (type == boolean.class) return Boolean.FALSE;
            if (type == byte.class) return (byte) 0;
            if (type == short.class) return (short) 0;
            if (type == int.class) return 0;
            if (type == long.class) return 0L;
            if (type == float.class) return 0f;
            if (type == double.class) return 0d;
            return '\0';
        }
    }

    private static final class ResultBinder extends Binder {
        final CountDownLatch latch = new CountDownLatch(1);
        volatile int value = Integer.MIN_VALUE;

        ResultBinder() {
            attachInterface(null, "android.net.IIntResultListener");
        }

        @Override
        protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) {
            try {
                if (code == 1) {
                    try {
                        data.enforceInterface("android.net.IIntResultListener");
                        value = data.readInt();
                    } catch (Throwable t) {
                        data.setDataPosition(data.dataSize() - 4);
                        value = data.readInt();
                    }
                    latch.countDown();
                    return true;
                }
                return super.onTransact(code, data, reply, flags);
            } catch (Throwable t) {
                return false;
            }
        }
    }

    private static final class ResultListener implements InvocationHandler {
        private final ResultBinder binder;

        ResultListener(ResultBinder binder) {
            this.binder = binder;
        }

        @Override
        public Object invoke(Object proxy, Method method, Object[] args) {
            String name = method.getName();
            if ("asBinder".equals(name)) return binder;
            if ("onResult".equals(name)) return null;
            if ("hashCode".equals(name)) return System.identityHashCode(proxy);
            if ("equals".equals(name)) return proxy == (args == null ? null : args[0]);
            if ("toString".equals(name)) return "HspResultProbe";
            return null;
        }
    }
}
