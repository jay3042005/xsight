package com.xsight.xsight_app

import android.app.PendingIntent
import android.content.*
import android.hardware.usb.*
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.*
import java.util.concurrent.Executors

class MainActivity : FlutterActivity(), MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val name = "xsight_usb_serial"
    private lateinit var usb: UsbManager
    private var conn: UsbDeviceConnection? = null
    private var input: UsbEndpoint? = null
    private var output: UsbEndpoint? = null
    private var sink: EventChannel.EventSink? = null
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var connectionToken = 0
    private var pending: MethodChannel.Result? = null
    private var pendingDevice: UsbDevice? = null
    private val permission = "com.xsight.xsight_app.USB_PERMISSION"
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != permission) return
            val result = pending
            pending = null
            if (!intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                result?.error("USB_PERMISSION", "Android did not grant USB permission", null)
                return
            }
            val device = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
            } else {
                @Suppress("DEPRECATION") intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
            }
            val target = device ?: pendingDevice ?: findDevice()
            pendingDevice = null
            val opened = open(target)
            if (opened) result?.success(true)
            else result?.error("USB_OPEN", lastError, null)
        }
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        usb = getSystemService(Context.USB_SERVICE) as UsbManager
        MethodChannel(engine.dartExecutor.binaryMessenger, name).setMethodCallHandler(this)
        EventChannel(engine.dartExecutor.binaryMessenger, "$name/events").setStreamHandler(this)
        val filter = IntentFilter(permission)
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(receiver, filter, RECEIVER_EXPORTED)
        else @Suppress("DEPRECATION") registerReceiver(receiver, filter)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "connect" -> {
                val device = findDevice()
                if (device == null) result.error("USB_NOT_FOUND", "No USB serial device detected", null)
                else if (!usb.hasPermission(device)) {
                    pending = result
                    pendingDevice = device
                    // Android 14+ rejects mutable PendingIntents carrying implicit intents.
                    // Package the broadcast and keep the PendingIntent immutable.
                    val intent = Intent(permission).setPackage(packageName)
                    val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    usb.requestPermission(device, PendingIntent.getBroadcast(this, 0, intent, flags))
                } else if (open(device)) result.success(true)
                else result.error("USB_OPEN", lastError, null)
            }
            "write" -> result.success(write(call.argument<ByteArray>("data") ?: ByteArray(0)))
            "disconnect" -> { close(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    private fun findDevice(): UsbDevice? = usb.deviceList.values.firstOrNull { d ->
        (0 until d.interfaceCount).any { d.getInterface(it).interfaceClass == 2 || d.getInterface(it).interfaceClass == 10 || d.getInterface(it).interfaceClass == 255 }
    }

    private var lastError = "USB interface could not be opened"

    private fun open(device: UsbDevice?): Boolean {
        if (device == null) { lastError = "USB device disappeared"; return false }
        close()
        val intf = (0 until device.interfaceCount).map { device.getInterface(it) }.firstOrNull { it.endpointCount >= 2 }
        if (intf == null) { lastError = "USB device has no bulk serial interface"; return false }
        val c = usb.openDevice(device) ?: run { lastError = "Android could not open USB device"; return false }
        if (!c.claimInterface(intf, true)) { c.close(); lastError = "Could not claim USB serial interface"; return false }
        conn = c
        val token = ++connectionToken
        for (i in 0 until intf.endpointCount) {
            val ep = intf.getEndpoint(i)
            if (ep.direction == UsbConstants.USB_DIR_IN) input = ep else output = ep
        }
        if (!configureSerial(c, device, intf)) {
            close()
            lastError = "USB opened, but serial baud/control setup failed"
            return false
        }
        executor.execute { readLoop(token, c, input) }
        if (input == null || output == null) {
            close()
            lastError = "USB serial interface has no input/output endpoints"
            return false
        }
        return true
    }

    private fun configureSerial(c: UsbDeviceConnection, device: UsbDevice, intf: UsbInterface): Boolean {
        // CDC ACM: 115200 8N1, then assert DTR/RTS.
        if (intf.interfaceClass == UsbConstants.USB_CLASS_COMM || intf.interfaceClass == UsbConstants.USB_CLASS_CDC_DATA) {
            val coding = byteArrayOf(0x00, 0xC2.toByte(), 0x01, 0x00, 0, 0, 8)
            val line = c.controlTransfer(UsbConstants.USB_DIR_OUT or UsbConstants.USB_TYPE_CLASS or 1, 0x20, 0, intf.id, coding, coding.size, 1000)
            val state = c.controlTransfer(UsbConstants.USB_DIR_OUT or UsbConstants.USB_TYPE_CLASS or 1, 0x22, 3, intf.id, null, 0, 1000)
            return line >= 0 && state >= 0
        }
        // Silicon Labs CP210x: baud 115200, 8N1, DTR + RTS.
        if (device.vendorId == 0x10C4) {
            val baud = byteArrayOf(0x00, 0xC2.toByte(), 0x01, 0x00)
            val baudResult = c.controlTransfer(UsbConstants.USB_DIR_OUT or UsbConstants.USB_TYPE_VENDOR or 1, 0x1E, 0, 0, baud, baud.size, 1000)
            val lineResult = c.controlTransfer(UsbConstants.USB_DIR_OUT or UsbConstants.USB_TYPE_VENDOR or 1, 0x03, 0x0800, 0, null, 0, 1000)
            val modemResult = c.controlTransfer(UsbConstants.USB_DIR_OUT or UsbConstants.USB_TYPE_VENDOR or 1, 0x07, 0x0303, 0, null, 0, 1000)
            return baudResult >= 0 && lineResult >= 0 && modemResult >= 0
        }
        return true
    }

    private fun readLoop(token: Int, readConnection: UsbDeviceConnection, readEndpoint: UsbEndpoint?) {
        val buffer = ByteArray(512)
        while (connectionToken == token && conn === readConnection && readEndpoint != null) {
            val count = readConnection.bulkTransfer(readEndpoint, buffer, buffer.size, 1000)
            if (count > 0) {
                val payload = buffer.copyOf(count)
                mainHandler.post {
                    if (connectionToken == token) sink?.success(payload)
                }
            }
        }
    }

    private fun write(data: ByteArray): Boolean {
        val c = conn ?: return false
        val ep = output ?: return false
        return c.bulkTransfer(ep, data, data.size, 1000) >= 0
    }
    private fun close() { connectionToken++; conn?.close(); conn = null; input = null; output = null }
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }
    override fun onDestroy() { close(); executor.shutdownNow(); unregisterReceiver(receiver); super.onDestroy() }
}
