package com.example.balanceandroid.sync

import androidx.room.withTransaction
import com.example.balanceandroid.data.AppDatabase
import com.example.balanceandroid.data.BudgetEntity
import com.example.balanceandroid.data.CategoryEntity
import com.example.balanceandroid.data.TransactionEntity
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

data class SyncStatus(
    val running: Boolean = false,
    val message: String? = null,
    val lastSyncAt: Long? = null,
)

class SyncRepository(
    private val database: AppDatabase,
    private val preferences: ServerPreferences,
    private val sessions: SecureSessionStore,
) {
    private val dao = database.financeDao()
    private val api = ServerApi(preferences, sessions)
    private val mutex = Mutex()
    private val mutableStatus = MutableStateFlow(SyncStatus())
    private val mutableSession = MutableStateFlow(sessions.load())
    val status: StateFlow<SyncStatus> = mutableStatus
    val session: StateFlow<ServerSession?> = mutableSession

//    fun serverUrl(): String = preferences.serverUrl
//    fun savedEmail(): String = preferences.email

    suspend fun changeServer(value: String): String {
        return try {
            val normalized = preferences.normalizeServer(value)
            val changed = normalized != preferences.serverUrl
            if (changed) {
                runCatching { api.logout() }
                sessions.clear()
                mutableSession.value = null
                preferences.serverUrl = normalized
            }
            mutableStatus.value = SyncStatus(message = if (changed) "Адрес сохранён. Войдите заново." else "Адрес сохранён")
            normalized
        } catch (error: Throwable) {
            mutableStatus.value = SyncStatus(message = error.message ?: "Некорректный адрес сервера")
            throw error
        }
    }

    suspend fun register(email: String, password: String) = authenticate(email) { api.register(email, password) }
    suspend fun login(email: String, password: String) = authenticate(email) { api.login(email, password) }

    private suspend fun authenticate(email: String, action: suspend () -> ServerSession) {
        mutableStatus.value = SyncStatus(running = true)
        runCatching { action() }
            .onSuccess {
                preferences.email = email.trim()
                mutableSession.value = it
                mutableStatus.value = SyncStatus(message = "Вход выполнен")
                sync()
            }
            .onFailure { mutableStatus.value = SyncStatus(message = it.message ?: "Ошибка входа") }
    }

    suspend fun logout() {
        if (mutableStatus.value.running) return
        runCatching { api.logout() }
        sessions.clear()
        mutableSession.value = null
        mutableStatus.value = SyncStatus(message = "Вы вышли из аккаунта")
    }

    suspend fun resetAndSync() {
        val session = sessions.load() ?: return
        preferences.resetSync(scope(session))
        sync()
    }

    suspend fun sync(): Boolean = mutex.withLock {
        val session = sessions.load() ?: return@withLock false
        if (preferences.serverUrl.isBlank()) return@withLock false
        mutableSession.value = session
        mutableStatus.value = mutableStatus.value.copy(running = true, message = null)
        val result = runCatching {
            val scope = scope(session)
            val cutoff = System.currentTimeMillis()
            val lastPush = preferences.lastPush(scope)
            val threshold = if (lastPush <= cutoff + 5_000) (lastPush - 5_000).coerceAtLeast(0) else 0
            val cursor = preferences.cursor(scope)

            pushTransactions(threshold, cutoff, cursor)
            pushCategories(threshold, cutoff, cursor)
            pushBudgets(threshold, cutoff, cursor)
            pushDeletions(cutoff, cursor)
            pull(scope, cursor)
            preferences.setLastPush(scope, cutoff)
        }
        return@withLock result.fold(
            onSuccess = {
                val now = System.currentTimeMillis()
                mutableStatus.value = SyncStatus(message = "Синхронизация завершена", lastSyncAt = now)
                true
            },
            onFailure = {
                if (it is ServerException && it.status == 401) {
                    sessions.clear()
                    mutableSession.value = null
                }
                mutableStatus.value = SyncStatus(message = it.message ?: "Ошибка синхронизации")
                false
            },
        )
    }

    private suspend fun pushTransactions(after: Long, through: Long, cursor: Long) {
        var offset = 0
        while (true) {
            val items = dao.transactionChanges(after, through, BATCH_SIZE, offset)
            if (items.isEmpty()) break
            push(cursor, items.map(::transactionChange))
            offset += items.size
            if (items.size < BATCH_SIZE) break
        }
    }

    private suspend fun pushCategories(after: Long, through: Long, cursor: Long) {
        var offset = 0
        while (true) {
            val items = dao.categoryChanges(after, through, BATCH_SIZE, offset)
            if (items.isEmpty()) break
            push(cursor, items.map(::categoryChange))
            offset += items.size
            if (items.size < BATCH_SIZE) break
        }
    }

    private suspend fun pushBudgets(after: Long, through: Long, cursor: Long) {
        var offset = 0
        while (true) {
            val items = dao.budgetChanges(after, through, BATCH_SIZE, offset)
            if (items.isEmpty()) break
            push(cursor, items.map(::budgetChange))
            offset += items.size
            if (items.size < BATCH_SIZE) break
        }
    }

    private suspend fun pushDeletions(through: Long, cursor: Long) {
        var offset = 0
        while (true) {
            val items = dao.deletionChanges(through, BATCH_SIZE, offset)
            if (items.isEmpty()) break
            push(cursor, items.map {
                JSONObject().put("entity", it.entity).put("id", it.recordId)
                    .put("deleted", true).put("updatedAt", iso(it.updatedAt))
            })
            offset += items.size
            if (items.size < BATCH_SIZE) break
        }
    }

    private suspend fun push(cursor: Long, changes: List<JSONObject>) {
        if (changes.isEmpty()) return
        val array = JSONArray().apply { changes.forEach { put(it) } }
        if (array.toString().toByteArray().size > 1_500_000 && changes.size > 1) {
            val middle = changes.size / 2
            push(cursor, changes.subList(0, middle))
            push(cursor, changes.subList(middle, changes.size))
        } else {
            api.sync(cursor, array, pull = false)
        }
    }

    private suspend fun pull(scope: String, initialCursor: Long) {
        var cursor = initialCursor
        do {
            val page = api.sync(cursor, JSONArray(), pull = true)
            require(page.cursor >= cursor) { "Сервер вернул некорректный курсор" }
            database.withTransaction { apply(page.changes) }
            preferences.setCursor(scope, page.cursor)
            if (!page.hasMore) return
            require(page.cursor > cursor) { "Сервер не смог продолжить синхронизацию" }
            cursor = page.cursor
        } while (true)
    }

    private suspend fun apply(changes: JSONArray) {
        val sorted = (0 until changes.length()).mapNotNull { changes.optJSONObject(it) }
            .sortedBy { it.optLong("sequence") }
        for (change in sorted) {
            val entity = change.optString("entity")
            val id = change.optString("id")
            val updatedAt = parseTime(change.optString("updatedAt")) ?: continue
            if (change.optBoolean("deleted")) {
                when (entity) {
                    "transaction" -> dao.transaction(id)?.takeIf { it.updatedAt <= updatedAt }?.let { dao.deleteTransactionDirect(id) }
                    "category" -> dao.category(id)?.takeIf { it.updatedAt <= updatedAt }?.let { dao.deleteCategoryDirect(id) }
                    "budget" -> dao.budget(id)?.takeIf { it.updatedAt <= updatedAt }?.let { dao.deleteBudgetDirect(id) }
                }
            } else {
                val payload = change.optJSONObject("payload") ?: continue
                runCatching {
                    when (entity) {
                        "transaction" -> applyTransaction(id, updatedAt, payload)
                        "category" -> applyCategory(id, updatedAt, payload)
                        "budget" -> applyBudget(id, updatedAt, payload)
                    }
                }
            }
            dao.clearDeletion(entity, id, updatedAt)
        }
    }

    private suspend fun applyTransaction(id: String, updatedAt: Long, value: JSONObject) {
        if ((dao.transaction(id)?.updatedAt ?: Long.MIN_VALUE) >= updatedAt) return
        dao.upsertTransaction(TransactionEntity(
            id = id,
            amount = value.getDouble("amount"),
            date = requireTime(value.getString("date")),
            note = value.optString("note"),
            categoryName = value.getString("categoryName"),
            categoryIcon = value.optString("categoryIcon", "circle"),
            categoryEmoji = value.optString("categoryEmoji"),
            categoryColorName = value.optString("categoryColorName", "indigo"),
            isBalanceAdjustment = value.optBoolean("isBalanceAdjustment"),
            kindRawValue = value.optString("kindRawValue", "expense"),
            updatedAt = updatedAt,
        ))
    }

    private suspend fun applyCategory(id: String, updatedAt: Long, value: JSONObject) {
        if ((dao.category(id)?.updatedAt ?: Long.MIN_VALUE) >= updatedAt) return
        dao.upsertCategory(CategoryEntity(
            id = id,
            name = value.getString("name"),
            icon = value.optString("icon", "star"),
            emoji = value.optString("emoji"),
            colorName = value.optString("colorName", "indigo"),
            kindRawValue = value.optString("kindRawValue", "expense"),
            createdAt = requireTime(value.getString("createdAt")),
            updatedAt = updatedAt,
        ))
    }

    private suspend fun applyBudget(id: String, updatedAt: Long, value: JSONObject) {
        if ((dao.budget(id)?.updatedAt ?: Long.MIN_VALUE) >= updatedAt) return
        dao.upsertBudget(BudgetEntity(
            id = id,
            categoryName = value.getString("categoryName"),
            categoryIcon = value.optString("categoryIcon", "circle"),
            categoryEmoji = value.optString("categoryEmoji"),
            limitAmount = value.getDouble("limit"),
            monthStart = requireTime(value.getString("monthStart")),
            updatedAt = updatedAt,
        ))
    }

    private fun transactionChange(value: TransactionEntity) = change("transaction", value.id, value.updatedAt, JSONObject()
        .put("amount", value.amount).put("date", iso(value.date)).put("note", value.note)
        .put("categoryName", value.categoryName).put("categoryIcon", value.categoryIcon)
        .put("categoryEmoji", value.categoryEmoji).put("categoryColorName", value.categoryColorName)
        .put("isBalanceAdjustment", value.isBalanceAdjustment).put("kindRawValue", value.kindRawValue))

    private fun categoryChange(value: CategoryEntity) = change("category", value.id, value.updatedAt, JSONObject()
        .put("name", value.name).put("icon", value.icon).put("emoji", value.emoji)
        .put("colorName", value.colorName).put("kindRawValue", value.kindRawValue)
        .put("createdAt", iso(value.createdAt)))

    private fun budgetChange(value: BudgetEntity) = change("budget", value.id, value.updatedAt, JSONObject()
        .put("categoryName", value.categoryName).put("categoryIcon", value.categoryIcon)
        .put("categoryEmoji", value.categoryEmoji).put("limit", value.limitAmount)
        .put("monthStart", iso(value.monthStart)))

    private fun change(entity: String, id: String, updatedAt: Long, payload: JSONObject) = JSONObject()
        .put("entity", entity).put("id", id).put("deleted", false)
        .put("updatedAt", iso(updatedAt)).put("payload", payload)

    private fun scope(session: ServerSession) = "${preferences.serverUrl}|${session.userId}"
    private fun iso(value: Long): String = Instant.ofEpochMilli(value).toString()
    private fun parseTime(value: String): Long? = runCatching { Instant.parse(value).toEpochMilli() }.getOrNull()
    private fun requireTime(value: String): Long = Instant.parse(value).toEpochMilli()

    companion object { private const val BATCH_SIZE = 100 }
}
