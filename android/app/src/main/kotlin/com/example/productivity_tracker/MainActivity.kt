package com.example.productivity_tracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.util.Log
import device.sdk.ScanManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

/**
 * Native scan bridge for rugged Android handhelds.
 *
 * WHY THIS EXISTS AT ALL, because the next person to read it will need it:
 * an ordinary Android app cannot receive scans on Point Mobile firmware. The
 * physical trigger, the beep, the LED and the successful decode all happen —
 * you can watch them in adb logcat — but the decoded string is delivered only
 * through Point Mobile's private IPC. Two symptoms follow:
 *
 *   * A BroadcastReceiver on `device.scanner.RESULT`, the action Point
 *     Mobile's public docs name, hears nothing. What their firmware ACTUALLY
 *     fires is `device.scanner.EVENT` — a different name, undocumented.
 *   * The scan engine turns its own enabled bit off between app switches, so
 *     without re-arming on onResume() the trigger goes dead the moment the
 *     operator opens ScanSettings and comes back.
 *
 * EmKit — Point Mobile's .aar under android/app/libs — fixes both, giving us
 * aDecodeSetTriggerEnable / aDecodeSetDecodeEnable to keep the engine armed,
 * and the broadcast the firmware really sends.
 *
 * THIS IS ADDITIVE. Handhelds configured for keyboard-wedge output (CipherLab
 * RS35 and most Zebras ship that way) already work: the engine types the
 * barcode into whichever field has focus and the existing screens submit on
 * Enter. Nothing here changes that path. This adds the intent path for the
 * devices whose wedge does not deliver keys to Flutter at all, and both paths
 * converge on the same Dart handler — see hardware_scanner.dart.
 *
 * EVERY EMKIT CALL IS WRAPPED. The SDK classes are absent on any non-Point
 * Mobile device, and an unguarded reference would take the app down at launch
 * on an ordinary phone, which is what most of this office tests on.
 */
class MainActivity : FlutterActivity() {

    private var receiver: ScanIntentReceiver? = null
    private var scanManager: ScanManager? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    receiver = registerReceiver(events)
                    initScanEngine()
                }

                override fun onCancel(arguments: Any?) {
                    receiver?.let { unregisterSafely(it) }
                    receiver = null
                    releaseScanEngine()
                }
            })
    }

    /**
     * Re-arm on resume. Point Mobile's ScannerService clears the enabled bit
     * when we lose focus, so without this the trigger is dead after any trip
     * out of the app — and "the trigger stopped working" is what gets reported,
     * with nothing in the app to explain it.
     */
    override fun onResume() {
        super.onResume()
        if (receiver != null) armScanEngine()
    }

    override fun onDestroy() {
        receiver?.let { unregisterSafely(it) }
        receiver = null
        releaseScanEngine()
        super.onDestroy()
    }

    // ---- Receiver ---------------------------------------------------------

    private fun registerReceiver(sink: EventChannel.EventSink): ScanIntentReceiver {
        val filter = IntentFilter().apply {
            SCAN_ACTIONS.forEach { addAction(it) }
        }
        val r = ScanIntentReceiver(sink)
        // Android 13+ requires an explicit exported flag; older APIs ignore it.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(r, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(r, filter)
        }
        return r
    }

    private fun unregisterSafely(r: BroadcastReceiver) {
        try {
            unregisterReceiver(r)
        } catch (_: IllegalArgumentException) {
            // Already gone. onCancel and onDestroy can arrive back to back on
            // the platform side; harmless.
        }
    }

    // ---- Scan engine (EmKit) ---------------------------------------------

    private fun initScanEngine() {
        try {
            val sm = ScanManager.getInstance()
            sm.aDecodeAPIInit()
            scanManager = sm
            armScanEngine()
            Log.i(TAG, "EmKit initialised, version=${sm.aDecodeGetAPIVersion()}")
        } catch (t: Throwable) {
            // Expected on every device that is not a Point Mobile handheld.
            // The keyboard-wedge path still works, so this is information,
            // not a failure.
            Log.i(TAG, "EmKit absent (${t.javaClass.simpleName}) — wedge path only")
        }
    }

    private fun armScanEngine() {
        val sm = scanManager ?: return
        try {
            // Point Mobile ships resultType = RESULT_CTRLV (5): the scanner
            // copies the decode to the clipboard and types Ctrl+V. That only
            // lands when a TextField happens to be focused, and produces
            // mangled input when one is not. RESULT_EVENT (3) makes
            // ScannerService fire the `device.scanner.EVENT` broadcast this
            // receiver is listening for instead. Verified against
            // device.common.ScanConst$ResultType in EmkitSDK.A11-3.24.1.aar.
            sm.aDecodeSetResultType(3)
            sm.aDecodeSetDecodeEnable(1)     // engine on
            sm.aDecodeSetTriggerEnable(1)    // physical trigger fires the engine
            Log.i(TAG, "armed: resultType=EVENT decode=1 trigger=1")
        } catch (t: Throwable) {
            Log.w(TAG, "arm failed: ${t.message}")
        }
    }

    private fun releaseScanEngine() {
        val sm = scanManager ?: return
        try {
            sm.aDecodeAPIDeinit()
        } catch (_: Throwable) {
            // Best effort. Releasing must never take the app down.
        }
        scanManager = null
    }

    // ---- Receiver implementation ----------------------------------------

    private class ScanIntentReceiver(
        private val sink: EventChannel.EventSink,
    ) : BroadcastReceiver() {

        override fun onReceive(context: Context, intent: Intent) {
            val extraKeys = intent.extras?.keySet()?.joinToString(",") ?: "<none>"
            Log.i(TAG, "onReceive action=${intent.action} extras=[$extraKeys]")

            // A FAILED READ IS NOT A BARCODE.
            //
            // Point Mobile broadcasts on every trigger pull, successful or
            // not, and when the engine cannot decode anything it puts the
            // literal string "READ_FAIL" in the decode value. Forwarding that
            // sent it all the way to the server, which answered "READ_FAIL is
            // not a label this system printed" — a red banner blaming the
            // operator for aiming slightly wrong, once per missed pull.
            //
            // Checked two ways because the firmware is not documented and the
            // string is not an SDK constant: the explicit result flag when the
            // firmware sets one, and the sentinel value otherwise.
            if (!decodeSucceeded(intent)) {
                Log.i(TAG, "read failed — nothing to forward")
                return
            }

            // Two shapes carry a decode on these devices:
            //   1. device.scanner.EVENT with EXTRA_EVENT_DECODE_VALUE (bytes)
            //      plus EXTRA_EVENT_DECODE_LENGTH. This is what current Point
            //      Mobile firmware actually fires.
            //   2. device.scanner.RESULT and the vendor aliases, with the
            //      decode as a plain string extra. Older firmware, and the
            //      other vendors that reuse this SDK.
            val payload = extractDecodedBytes(intent) ?: extractDecodedString(intent)
            if (payload.isNullOrBlank()) {
                Log.w(TAG, "no known extra key held decoded data")
                return
            }
            Log.i(TAG, "FORWARD len=${payload.length}")
            sink.success(payload.trim())
        }

        /**
         * Whether this broadcast carries a real decode.
         *
         * The firmware fires on EVERY trigger pull. Two independent signals
         * say a pull found nothing, and both are checked because neither is
         * documented and "READ_FAIL" is not an SDK constant — it is a string
         * the ScannerService invents:
         *
         *   * EXTRA_EVENT_DECODE_RESULT, when the firmware sets it. Seen as
         *     both a boolean and an int depending on build, so both are read.
         *   * the decode value being the sentinel itself.
         */
        private fun decodeSucceeded(intent: Intent): Boolean {
            val extras = intent.extras
            if (extras != null && extras.containsKey(EXTRA_EVENT_DECODE_RESULT)) {
                when (val flag = extras.get(EXTRA_EVENT_DECODE_RESULT)) {
                    is Boolean -> if (!flag) return false
                    is Int -> if (flag == 0) return false
                    is String -> if (flag.equals(READ_FAIL, ignoreCase = true)) return false
                }
            }
            val value = extractDecodedBytes(intent) ?: extractDecodedString(intent)
            return value != null && !value.trim().equals(READ_FAIL, ignoreCase = true)
        }

        /**
         * Point Mobile sends the barcode as a `byte[]`, not a String — their
         * decode pipeline is byte-oriented and preserves the original codepage.
         * UTF-8 is the convention for QR.
         */
        private fun extractDecodedBytes(intent: Intent): String? {
            val bytes = intent.getByteArrayExtra(EXTRA_EVENT_DECODE_VALUE)
                ?: intent.getByteArrayExtra(EXTRA_EVENT_BYTES_VALUE)
                ?: return null
            val length = intent.getIntExtra(EXTRA_EVENT_DECODE_LENGTH, bytes.size)
                .coerceAtMost(bytes.size)
            return String(bytes, 0, length, Charsets.UTF_8)
        }

        private fun extractDecodedString(intent: Intent): String? = DATA_KEYS
            .asSequence()
            .mapNotNull { intent.getStringExtra(it) }
            .firstOrNull { it.isNotBlank() }
    }

    companion object {
        private const val TAG = "VistarScanIntent"

        /** Must match `_scanIntentChannel` in lib/core/scanner/hardware_scanner.dart. */
        private const val CHANNEL_NAME = "vistar_productivity/scan_intents"

        // Every action known to carry a decode on a rugged handheld. Order is
        // irrelevant — the first matching receiver wins.
        private val SCAN_ACTIONS = listOf(
            "device.scanner.EVENT",                   // Point Mobile, current firmware
            "device.scanner.RESULT",                  // Point Mobile, legacy
            "com.pointmobile.scanner.RESULT",         // Point Mobile alternate
            "com.pointmobile.action.SCANNED_DATA",    // Older Point Mobile
            "com.rscja.scanner.action.BARCODE",       // Chainway
            "nlscan.action.SCANNER_RESULT",           // Newland
            "com.symbol.datawedge.api.RESULT_ACTION", // Zebra DataWedge default
            // CipherLab AndroidReaderConfig, stable across RS31/RS35/RK25/9700.
            // Fires only when the on-device ReaderConfig app is set to
            // Data Output -> Intent. Its default is Keyboard Emulation, and in
            // that mode the Dart side's keyboard path catches the scan instead.
            "com.cipherlab.barcode.GeneralString.Intent_PASS_TO_APP",
        )

        // Byte-array extras, kept in sync with device.common.ScanConst.
        private const val EXTRA_EVENT_DECODE_VALUE = "EXTRA_EVENT_DECODE_VALUE"
        private const val EXTRA_EVENT_BYTES_VALUE = "EXTRA_EVENT_BYTES_VALUE"
        private const val EXTRA_EVENT_DECODE_LENGTH = "EXTRA_EVENT_DECODE_LENGTH"

        /** Set by the firmware on a pull that decoded nothing. */
        private const val EXTRA_EVENT_DECODE_RESULT = "EXTRA_EVENT_DECODE_RESULT"

        /**
         * What the ScannerService puts in the decode value when the engine
         * read nothing. Not an SDK constant — it appears nowhere in
         * EmkitSDK.A11-3.24.1.aar — so it is matched literally.
         */
        private const val READ_FAIL = "READ_FAIL"

        // String extras seen on older firmware and other vendors.
        private val DATA_KEYS = listOf(
            "EXTRA_BARCODE_DECODING_DATA",                     // Point Mobile, older docs
            "barcode_string",                                  // Point Mobile alternate
            "SCAN_BARCODE1",                                   // Chainway
            "SCAN_BARCODE_TEXT",                               // Newland
            "com.symbol.datawedge.data_string",                // Zebra DataWedge
            "com.cipherlab.barcode.GeneralString.BcReaderData",// CipherLab
        )
    }
}
