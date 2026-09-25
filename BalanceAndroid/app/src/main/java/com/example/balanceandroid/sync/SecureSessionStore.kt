package com.example.balanceandroid.sync

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import androidx.core.content.edit

data class ServerSession(
    val accessToken: String,
    val refreshToken: String,
    val expiresAt: Long,
    val userId: String,
    val email: String,
)

class SecureSessionStore(context: Context) {
    private val preferences = context.getSharedPreferences("balance_secure_session", Context.MODE_PRIVATE)
    private val alias = "balance.server.session.key"

    fun save(session: ServerSession) {
        val source = JSONObject()
            .put("accessToken", session.accessToken)
            .put("refreshToken", session.refreshToken)
            .put("expiresAt", session.expiresAt)
            .put("userId", session.userId)
            .put("email", session.email)
            .toString().toByteArray()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        preferences.edit {
            putString("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
                .putString("data", Base64.encodeToString(cipher.doFinal(source), Base64.NO_WRAP))
        }
    }

    fun load(): ServerSession? = runCatching {
        val iv = Base64.decode(preferences.getString("iv", null), Base64.NO_WRAP)
        val encrypted = Base64.decode(preferences.getString("data", null), Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, iv))
        val json = JSONObject(String(cipher.doFinal(encrypted)))
        ServerSession(
            accessToken = json.getString("accessToken"),
            refreshToken = json.getString("refreshToken"),
            expiresAt = json.getLong("expiresAt"),
            userId = json.getString("userId"),
            email = json.getString("email"),
        )
    }.getOrElse {
        clear()
        null
    }

    fun clear() {
        preferences.edit { clear() }
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(
                    alias,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .build()
            )
            generateKey()
        }
    }
}
