package com.balance.runtime;

import android.os.Handler;
import android.os.Looper;
import java.io.File;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** Serializes complete ledger/session operations across Flutter engines/processes. */
public final class BalanceRuntimePlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Object state = new Object();
    private MethodChannel channel;
    private ExecutorService executor;
    private File lockFile;
    private boolean detached = true;
    private boolean acquiring;
    private LedgerFileLock held;

    @Override
    public void onAttachedToEngine(FlutterPluginBinding binding) {
        synchronized (state) {
            detached = false;
            acquiring = false;
            lockFile = new File(binding.getApplicationContext().getFilesDir(), "balance-runtime.lock");
            executor = Executors.newSingleThreadExecutor();
        }
        channel = new MethodChannel(binding.getBinaryMessenger(), "balance/runtime");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        if ("acquireLock".equals(call.method)) {
            synchronized (state) {
                if (detached || acquiring || held != null) {
                    result.error("lock_busy", "This engine already owns or is waiting for the ledger lock", null);
                    return;
                }
                acquiring = true;
                executor.execute(() -> acquire(result));
            }
        } else if ("releaseLock".equals(call.method)) {
            LedgerFileLock release;
            synchronized (state) {
                String token = call.argument("token");
                if (held == null || !held.token.equals(token)) {
                    result.error("lock_owner", "Ledger lock token does not match this engine", null);
                    return;
                }
                release = held;
                held = null;
            }
            // Never queue release behind another engine's blocking acquisition.
            release.close();
            result.success(null);
        } else {
            result.notImplemented();
        }
    }

    private void acquire(MethodChannel.Result result) {
        try {
            LedgerFileLock acquired = LedgerFileLock.acquire(lockFile);
            synchronized (state) {
                acquiring = false;
                if (detached) {
                    acquired.close();
                    return;
                }
                held = acquired;
            }
            main.post(() -> {
                synchronized (state) {
                    if (detached || held != acquired) return;
                    result.success(acquired.token);
                }
            });
        } catch (Exception error) {
            synchronized (state) { acquiring = false; }
            main.post(() -> {
                synchronized (state) {
                    if (!detached) result.error("lock_failed", "Unable to acquire the local ledger lock", null);
                }
            });
        }
    }

    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        LedgerFileLock release;
        synchronized (state) {
            detached = true;
            release = held;
            held = null;
            if (executor != null) executor.shutdownNow();
        }
        if (channel != null) channel.setMethodCallHandler(null);
        if (release != null) release.close();
    }

}
