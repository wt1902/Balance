package com.balance.balance

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var channel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
        applyHideInRecents(prefs.getBoolean("flutter.privacy.hideInRecents", false))
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "initialAction" -> {
                    val value = intent?.getStringExtra(EXTRA_ACTION)
                    intent?.removeExtra(EXTRA_ACTION)
                    result.success(value)
                }
                "updateWidgets" -> {
                    updateWidgets()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        channel = ch
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PRIVACY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setHideInRecents" -> {
                        applyHideInRecents(call.arguments as? Boolean ?: false)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val value = intent.getStringExtra(EXTRA_ACTION) ?: return
        intent.removeExtra(EXTRA_ACTION)
        channel?.invokeMethod("action", value)
    }

    private fun applyHideInRecents(hide: Boolean) {
        if (Build.VERSION.SDK_INT >= 33) {
            setRecentsScreenshotEnabled(!hide)
        } else if (hide) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    private fun updateWidgets() {
        val manager = AppWidgetManager.getInstance(this)
        val component = ComponentName(this, BalanceWidgetProvider::class.java)
        val ids = manager.getAppWidgetIds(component)
        if (ids.isEmpty()) return
        sendBroadcast(
            Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE).apply {
                setComponent(component)
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
            },
        )
    }

    companion object {
        const val CHANNEL = "balance/launch"
        const val PRIVACY_CHANNEL = "balance/privacy"
        const val EXTRA_ACTION = "com.balance.balance.ACTION"
    }
}
