package com.example.balanceandroid.sync

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.time.Instant

class ServerException(message: String, val status: Int = 0) : Exception(message)

data class SyncPage(
    val cursor: Long,
    val changes: JSONArray,
    val hasMore: Boolean,
)

class ServerApi(
    private val preferences: ServerPreferences,
    private val sessions: SecureSessionStore,
) {
    suspend fun register(email: String, password: String): ServerSession = authenticate("v1/auth/register", email, password)
    suspend fun login(email: String, password: String): ServerSession = authenticate("v1/auth/login", email, password)

    suspend fun logout() {
        sessions.load()?.let { session ->
            runCatching { post("v1/auth/logout", JSONObject().put("refreshToken", session.refreshToken), null) }
        }
        sessions.clear()
    }

    suspend fun sync(cursor: Long, changes: JSONArray, pull: Boolean): SyncPage {
        val body = JSONObject()
            .put("cursor", cursor)
            .put("deviceId", preferences.deviceId)
            .put("changes", changes)
            .put("pull", pull)
        val response = authorizedPost("v1/sync", body)
        return SyncPage(
            cursor = response.optLong("cursor", cursor),
            changes = response.optJSONArray("changes") ?: JSONArray(),
            hasMore = response.optBoolean("hasMore", false),
        )
    }

    private suspend fun authenticate(path: String, email: String, password: String): ServerSession {
        val response = post(path, JSONObject().put("email", email.trim()).put("password", password), null)
        return parseSession(response).also { sessions.save(it) }
    }

    private suspend fun authorizedPost(path: String, body: JSONObject, retry: Boolean = true): JSONObject {
        var session = sessions.load() ?: throw ServerException("Сначала войдите в аккаунт")
        if (session.expiresAt - System.currentTimeMillis() < 60_000) session = refresh(session)
        return try {
            post(path, body, session.accessToken)
        } catch (error: ServerException) {
            if (error.status == 401 && retry) {
                session = refresh(session)
                post(path, body, session.accessToken)
            } else throw error
        }
    }

    private suspend fun refresh(session: ServerSession): ServerSession {
        return try {
            parseSession(post("v1/auth/refresh", JSONObject().put("refreshToken", session.refreshToken), null))
                .also { sessions.save(it) }
        } catch (_: Throwable) {
            sessions.clear()
            throw ServerException("Сессия истекла. Войдите снова.")
        }
    }

    private fun parseSession(json: JSONObject): ServerSession {
        val user = json.getJSONObject("user")
        return ServerSession(
            accessToken = json.getString("accessToken"),
            refreshToken = json.getString("refreshToken"),
            expiresAt = Instant.parse(json.getString("expiresAt")).toEpochMilli(),
            userId = user.getString("id"),
            email = user.getString("email"),
        )
    }

    private suspend fun post(path: String, body: JSONObject, token: String?): JSONObject = withContext(Dispatchers.IO) {
        val base = preferences.normalizeServer(preferences.serverUrl)
        val connection = (URL("$base/$path").openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 15_000
            readTimeout = 30_000
            doOutput = true
            setRequestProperty("Content-Type", "application/json; charset=utf-8")
            if (token != null) setRequestProperty("Authorization", "Bearer $token")
        }
        try {
            connection.outputStream.use { it.write(body.toString().toByteArray()) }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val text = stream?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (status !in 200..299) {
                val message = runCatching { JSONObject(text).getJSONObject("error").getString("message") }
                    .getOrDefault("Ошибка сервера: HTTP $status")
                throw ServerException(message, status)
            }
            if (text.isBlank()) JSONObject() else JSONObject(text)
        } finally {
            connection.disconnect()
        }
    }
}
