// OmniPlay SDK: Android Bluetooth adapter. Finds and connects fitness devices with Android's
// Bluetooth LE API and passes the bytes to the OmniPlay core (Lua or JS) through a Listener.
// Android allows one GATT operation at a time per device, so every subscribe / write goes
// through a queue here; that is the usual cause of "notifications never arrive" on Android.
//
//   OmniPlayBle ble = new OmniPlayBle(context, listener);
//   ble.scan(10000);                 // listener.onFound(...) for each fitness device nearby
//   ble.connect(address);            // onServices -> core add(); onReady -> core connected()
//   ble.write(address, charUuid, bytes)   // what the core's send() asks for
//
// Permissions (AndroidManifest.xml): BLUETOOTH_SCAN and BLUETOOTH_CONNECT on Android 12+,
// BLUETOOTH, BLUETOOTH_ADMIN and ACCESS_FINE_LOCATION before that. Ask for them at runtime first.
// License: OmniPlay SDK License (MIT + don't sell OmniPlay support separately).
package site.omniplay;

import android.annotation.SuppressLint;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanFilter;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelUuid;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

@SuppressLint("MissingPermission")
public class OmniPlayBle {
    public interface Listener {
        void onFound(String address, String name, int rssi);
        /** services and characteristics found: give uuids to the core's add(); return the characteristics to subscribe to (core notify_chars), or null if unsupported */
        String[] onServices(String address, String name, String[] uuids);
        /** subscriptions are on: call the core's connected() */
        void onReady(String address);
        /** a notification: core receive(address, charUuid, bytes) */
        void onData(String address, String charUuid, byte[] bytes);
        /** connection lost: core remove(address). OmniPlayBle reconnects by itself unless disconnect() was called */
        void onLost(String address);
    }

    /** the services OmniPlay knows (FTMS, CSC, RSC, heart rate, Sperax) */
    public static final String[] SERVICES = {
        "00001826-0000-1000-8000-00805f9b34fb", "00001816-0000-1000-8000-00805f9b34fb",
        "00001814-0000-1000-8000-00805f9b34fb", "0000180d-0000-1000-8000-00805f9b34fb",
        "0000fff0-0000-1000-8000-00805f9b34fb",
    };
    private static final UUID CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");

    private final Context context;
    private final Listener listener;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final BluetoothAdapter adapter;
    private final Map<String, Link> links = new HashMap<>();
    private ScanCallback scanCallback;

    private static class Op {
        final BluetoothGattCharacteristic ch; final byte[] value; final boolean subscribe;
        Op(BluetoothGattCharacteristic ch, byte[] value, boolean subscribe) { this.ch = ch; this.value = value; this.subscribe = subscribe; }
    }
    private class Link {
        final String address; String name; BluetoothGatt gatt; boolean wanted = true, busy = false, ready = false;
        final ArrayDeque<Op> queue = new ArrayDeque<>();
        final Map<String, BluetoothGattCharacteristic> chars = new HashMap<>();
        Link(String address) { this.address = address; }
    }

    public OmniPlayBle(Context context, Listener listener) {
        this.context = context.getApplicationContext();
        this.listener = listener;
        BluetoothManager bm = (BluetoothManager) this.context.getSystemService(Context.BLUETOOTH_SERVICE);
        this.adapter = bm != null ? bm.getAdapter() : null;
    }

    public boolean available() { return adapter != null && adapter.isEnabled(); }

    /** look for fitness devices for ms milliseconds. Sperax pads don't advertise their service, so names count too. */
    public void scan(long ms) {
        if (!available()) return;
        BluetoothLeScanner scanner = adapter.getBluetoothLeScanner();
        if (scanner == null) return;
        stopScan();
        scanCallback = new ScanCallback() {
            @Override public void onScanResult(int type, ScanResult r) {
                BluetoothDevice d = r.getDevice();
                String name = r.getScanRecord() != null ? r.getScanRecord().getDeviceName() : null;
                if (name == null) name = d.getName();
                boolean known = false;
                List<ParcelUuid> ids = r.getScanRecord() != null ? r.getScanRecord().getServiceUuids() : null;
                if (ids != null) for (ParcelUuid p : ids) for (String s : SERVICES) if (p.getUuid().toString().equalsIgnoreCase(s)) known = true;
                if (name != null && name.toUpperCase().startsWith("SPERAX")) known = true;
                if (known) listener.onFound(d.getAddress(), name != null ? name : d.getAddress(), r.getRssi());
            }
        };
        ScanSettings settings = new ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build();
        scanner.startScan(new ArrayList<ScanFilter>(), settings, scanCallback); // no filter: Sperax only shows by name
        main.postDelayed(this::stopScan, ms);
    }

    public void stopScan() {
        if (scanCallback != null && adapter != null && adapter.getBluetoothLeScanner() != null) adapter.getBluetoothLeScanner().stopScan(scanCallback);
        scanCallback = null;
    }

    public void connect(String address) {
        if (!available()) return;
        Link l = links.get(address);
        if (l == null) { l = new Link(address); links.put(address, l); }
        l.wanted = true;
        open(l);
    }

    private void open(Link l) {
        BluetoothDevice d = adapter.getRemoteDevice(l.address);
        l.name = d.getName() != null ? d.getName() : l.address;
        l.busy = false; l.ready = false; l.queue.clear(); l.chars.clear();
        l.gatt = d.connectGatt(context, false, callback(l), BluetoothDevice.TRANSPORT_LE);
    }

    public void disconnect(String address) {
        Link l = links.remove(address);
        if (l == null) return;
        l.wanted = false;
        if (l.gatt != null) { l.gatt.disconnect(); l.gatt.close(); }
    }

    /** the core's send(): write bytes to a characteristic, in order */
    public void write(String address, String charUuid, byte[] bytes) {
        Link l = links.get(address);
        if (l == null || !l.ready) return;
        BluetoothGattCharacteristic ch = l.chars.get(charUuid.toLowerCase());
        if (ch == null) return;
        l.queue.add(new Op(ch, bytes, false));
        next(l);
    }

    @SuppressWarnings("deprecation") // the old write API works on every Android version
    private void next(Link l) {
        if (l.busy || l.gatt == null) return;
        Op op = l.queue.poll();
        if (op == null) {
            if (!l.ready) { l.ready = true; listener.onReady(l.address); }
            return;
        }
        l.busy = true;
        boolean ok;
        if (op.subscribe) {
            l.gatt.setCharacteristicNotification(op.ch, true);
            BluetoothGattDescriptor cccd = op.ch.getDescriptor(CCCD);
            if (cccd == null) { l.busy = false; next(l); return; }
            boolean indicate = (op.ch.getProperties() & BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0
                && (op.ch.getProperties() & BluetoothGattCharacteristic.PROPERTY_NOTIFY) == 0;
            cccd.setValue(indicate ? BluetoothGattDescriptor.ENABLE_INDICATION_VALUE : BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE);
            ok = l.gatt.writeDescriptor(cccd);
        } else {
            boolean noResponse = (op.ch.getProperties() & BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0;
            op.ch.setWriteType(noResponse ? BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE : BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT);
            op.ch.setValue(op.value);
            ok = l.gatt.writeCharacteristic(op.ch);
        }
        if (!ok) { l.busy = false; main.postDelayed(() -> next(l), 50); }
    }

    private BluetoothGattCallback callback(final Link l) {
        return new BluetoothGattCallback() {
            @Override public void onConnectionStateChange(BluetoothGatt g, int status, int state) {
                main.post(() -> {
                    if (state == BluetoothProfile.STATE_CONNECTED) { g.discoverServices(); return; }
                    if (state != BluetoothProfile.STATE_DISCONNECTED) return;
                    boolean wasReady = l.ready;
                    l.ready = false; l.busy = false;
                    g.close();
                    if (wasReady) listener.onLost(l.address);
                    if (l.wanted) main.postDelayed(() -> { if (l.wanted) open(l); }, wasReady ? 1000 : 3000);
                });
            }
            @Override public void onServicesDiscovered(BluetoothGatt g, int status) {
                main.post(() -> {
                    List<String> uuids = new ArrayList<>();
                    for (BluetoothGattService s : g.getServices()) {
                        uuids.add(s.getUuid().toString());
                        for (BluetoothGattCharacteristic c : s.getCharacteristics()) {
                            uuids.add(c.getUuid().toString());
                            l.chars.put(c.getUuid().toString().toLowerCase(), c);
                        }
                    }
                    String[] sub = listener.onServices(l.address, l.name, uuids.toArray(new String[0]));
                    if (sub == null) { disconnect(l.address); return; }
                    for (String u : sub) {
                        BluetoothGattCharacteristic c = l.chars.get(u.toLowerCase());
                        if (c != null) l.queue.add(new Op(c, null, true));
                    }
                    next(l); // runs the subscriptions, then onReady
                });
            }
            @Override public void onDescriptorWrite(BluetoothGatt g, BluetoothGattDescriptor d, int status) {
                main.post(() -> { l.busy = false; next(l); });
            }
            @Override public void onCharacteristicWrite(BluetoothGatt g, BluetoothGattCharacteristic c, int status) {
                main.post(() -> { l.busy = false; next(l); });
            }
            @SuppressWarnings("deprecation")
            @Override public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic c) {
                final byte[] v = c.getValue() != null ? c.getValue().clone() : new byte[0];
                final String u = c.getUuid().toString();
                main.post(() -> listener.onData(l.address, u, v));
            }
        };
    }
}
