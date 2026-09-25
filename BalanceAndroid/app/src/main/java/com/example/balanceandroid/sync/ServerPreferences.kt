package com.example.balanceandroid.sync

import android.content.Context
import java.net.URI
import java.security.MessageDigest
import java.util.UUID
import androidx.core.content.edit

class ServerPreferences(context: Context) {
    private val values = context.getSharedPreferences("balance_settings", Context.MODE_PRIVATE)

    var serverUrl: String
        get() = values.getString("server_url", "") ?: ""
        set(value) { values.edit { putString("server_url", value) } }
    var email: String
        get() = values.getString("server_email", "") ?: ""
        set(value) { values.edit { putString("server_email", value) } }
    var currency: String
        get() = values.getString("currency", "RUB") ?: "RUB"
        set(value) { values.edit { putString("currency", value) } }
    var theme: String
        get() = values.getString("theme", "system") ?: "system"
        set(value) { values.edit { putString("theme", value) } }

    val deviceId: String
        get() = values.getString("device_id", null) ?: UUID.randomUUID().toString().also {
            values.edit { putString("device_id", it) }
        }

    fun normalizeServer(input: String): String {
        val trimmed = input.trim().trimEnd('/')
        val uri = runCatching { URI(trimmed) }.getOrNull()
            ?: error("Укажите полный адрес сервера")
        val host = uri.host?.lowercase() ?: error("Укажите полный адрес сервера")
        val scheme = uri.scheme?.lowercase()
        require(scheme == "https" || scheme == "http") { "Адрес должен начинаться с https://" }
        require(uri.userInfo == null && uri.rawQuery == null && uri.rawFragment == null) {
            "Адрес сервера не должен содержать логин, параметры или фрагмент"
        }
        if (scheme == "http") {
            require(host in setOf("localhost", "127.0.0.1", "10.0.2.2")) {
                "Для удалённого сервера требуется HTTPS"
            }
        }
        return trimmed
    }

    fun cursor(scope: String): Long = values.getLong("cursor_${hash(scope)}", 0).coerceAtLeast(0)
    fun setCursor(scope: String, cursor: Long) = values.edit {
        putLong(
            "cursor_${hash(scope)}",
            cursor
        )
    }
    fun lastPush(scope: String): Long = values.getLong("push_${hash(scope)}", 0)
    fun setLastPush(scope: String, value: Long) = values.edit {
        putLong(
            "push_${hash(scope)}",
            value
        )
    }
    fun resetSync(scope: String) {
        values.edit { remove("cursor_${hash(scope)}").remove("push_${hash(scope)}") }
    }

    private fun hash(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray()).take(12).joinToString("") { "%02x".format(it) }
}
