package com.balance.runtime;

import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.util.UUID;
import java.util.concurrent.Semaphore;
import java.util.concurrent.atomic.AtomicBoolean;

/** OS lock plus JVM serialization, independent of any Flutter engine lifetime. */
final class LedgerFileLock implements AutoCloseable {
    // FileChannel alone throws OverlappingFileLockException in one JVM.
    private static final Semaphore PROCESS_LOCK = new Semaphore(1, true);
    final String token = UUID.randomUUID().toString();
    private final RandomAccessFile file;
    private final FileChannel channel;
    private final FileLock lock;
    private final AtomicBoolean closed = new AtomicBoolean();

    private LedgerFileLock(RandomAccessFile file, FileChannel channel, FileLock lock) {
        this.file = file;
        this.channel = channel;
        this.lock = lock;
    }

    static LedgerFileLock acquire(File path) throws IOException, InterruptedException {
        PROCESS_LOCK.acquire();
        RandomAccessFile file = null;
        FileChannel channel = null;
        FileLock lock = null;
        try {
            file = new RandomAccessFile(path, "rw");
            channel = file.getChannel();
            lock = channel.lock();
            return new LedgerFileLock(file, channel, lock);
        } catch (IOException | RuntimeException error) {
            try { if (lock != null) lock.release(); } catch (IOException ignored) {}
            try { if (channel != null) channel.close(); } catch (IOException ignored) {}
            try { if (file != null) file.close(); } catch (IOException ignored) {}
            PROCESS_LOCK.release();
            throw error;
        }
    }

    @Override
    public void close() {
        if (!closed.compareAndSet(false, true)) return;
        try { lock.release(); } catch (IOException ignored) {}
        try { channel.close(); } catch (IOException ignored) {}
        try { file.close(); } catch (IOException ignored) {}
        PROCESS_LOCK.release();
    }
}
