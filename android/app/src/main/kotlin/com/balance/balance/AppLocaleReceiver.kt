package com.balance.balance

import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import dev.fluttercommunity.workmanager.SharedPreferenceHelper
import dev.fluttercommunity.workmanager.WorkManagerWrapper
import dev.fluttercommunity.workmanager.pigeon.ExistingWorkPolicy
import dev.fluttercommunity.workmanager.pigeon.OneOffTaskRequest

class AppLocaleReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_LOCALE_CHANGED) return
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        if (prefs.getString("flutter.appLanguage", null) in listOf("en", "ru")) return

        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(ComponentName(context, BalanceWidgetProvider::class.java))
        if (ids.isNotEmpty()) BalanceWidgetProvider().onUpdate(context, manager, ids)

        if (SharedPreferenceHelper.getCallbackHandle(context) == -1L) return
        runCatching {
            WorkManagerWrapper(context).enqueueOneOffTask(
                OneOffTaskRequest(
                    uniqueName = "balance-notification-language",
                    taskName = "balance.notifications.language",
                    existingWorkPolicy = ExistingWorkPolicy.REPLACE,
                ),
            )
        }
    }
}
