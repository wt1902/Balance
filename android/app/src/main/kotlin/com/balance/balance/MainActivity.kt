package com.balance.balance

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

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
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val value = intent.getStringExtra(EXTRA_ACTION) ?: return
        intent.removeExtra(EXTRA_ACTION)
        channel?.invokeMethod("action", value)
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
        const val EXTRA_ACTION = "com.balance.balance.ACTION"
    }
}
