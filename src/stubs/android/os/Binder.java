package android.os;
/** Compile-time stub only. Not packaged; the real class comes from the device boot classpath. */
public class Binder implements IBinder {
    public Binder() {}
    public void attachInterface(IInterface owner, String descriptor) {}
    protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws RemoteException { return false; }
}
