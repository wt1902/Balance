package com.balance.balance

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

class BalanceWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val balance = prefs.getString("flutter.widget.balance", null)
        val expenses = prefs.getString("flutter.widget.monthExpenses", null)
        val budget = prefs.getString("flutter.widget.budget", null)

        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.widget_balance)
            views.setTextViewText(R.id.widget_balance, balance ?: "Откройте приложение")
            views.setTextViewText(
                R.id.widget_expenses,
                if (expenses.isNullOrEmpty()) "" else "Расходы за месяц: $expenses",
            )
            views.setTextViewText(R.id.widget_budget, budget ?: "")
            views.setOnClickPendingIntent(R.id.widget_root, launch(context, null, 2))
            views.setOnClickPendingIntent(R.id.widget_add, launch(context, "expense", 3))
            appWidgetManager.updateAppWidget(id, views)
        }
    }

    private fun launch(context: Context, action: String?, requestCode: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            if (action != null) putExtra(MainActivity.EXTRA_ACTION, action)
        }
        return PendingIntent.getActivity(
            context, requestCode, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }
}
