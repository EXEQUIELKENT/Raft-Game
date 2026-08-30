package com.raftrumble.raft_rumble

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Holds a WifiManager MulticastLock for the lifetime of the LAN beacon/scan.
 *
 * Android's Wi-Fi chip filters out inbound multicast/broadcast traffic while
 * the screen is dimmed or the radio is in low-power mode, which is the root
 * cause behind "the scan sometimes just doesn't see a room that's definitely
 * there" — the beacon packets are being sent, they are simply dropped by the
 * receiving phone's radio before Dart ever sees them. Holding this lock while
 * a beacon or scan is active tells the radio to stop filtering.
 * `setReferenceCounted(true)` lets `acquire` (hosting) and `acquire`
 * (scanning) overlap safely — the lock is only actually released once every
 * caller has released it.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "raftrumble/multicast"
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        try {
                            val lock = multicastLock ?: run {
                                val wifi = applicationContext
                                    .getSystemService(Context.WIFI_SERVICE) as WifiManager
                                wifi.createMulticastLock("raftrumble-lan").apply {
                                    setReferenceCounted(true)
                                }.also { multicastLock = it }
                            }
                            lock.acquire()
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("multicast_lock", e.message, null)
                        }
                    }
                    "release" -> {
                        try {
                            multicastLock?.let { if (it.isHeld) it.release() }
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("multicast_lock", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
