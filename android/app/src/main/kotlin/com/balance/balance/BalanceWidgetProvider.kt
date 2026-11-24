package com.balance.balance

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.widget.RemoteViews
import java.util.Locale

class BalanceWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val language = when (prefs.getString("flutter.appLanguage", null)) {
            "ru" -> "ru"
            "en" -> "en"
            else -> if (context.resources.configuration.locales[0]?.language == "ru") "ru" else "en"
        }
        val resources = context.createConfigurationContext(
            Configuration(context.resources.configuration).apply {
                setLocale(Locale.forLanguageTag(language))
            },
        ).resources
        fun summary(key: String): String? =
            prefs.getString("flutter.widget.$key.$language", null)
                ?: if (language == "ru") prefs.getString("flutter.widget.$key", null) else null

        val balance = summary("balance")
        val expenses = summary("monthExpenses")
        val budget = summary("budget")

        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.widget_balance)
            views.setTextViewText(R.id.widget_title, resources.getString(R.string.widget_title))
            views.setContentDescription(R.id.widget_add, resources.getString(R.string.widget_add_expense))
            views.setTextViewText(
                R.id.widget_balance,
                balance ?: resources.getString(R.string.widget_open_app),
            )
            views.setTextViewText(
                R.id.widget_expenses,
                if (expenses.isNullOrEmpty()) "" else resources.getString(R.string.widget_month_expenses, expenses),
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
