package com.balance.runtime;

import static org.junit.Assert.*;
import java.io.File;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.file.Files;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.Test;

public class LedgerFileLockTest {
    @Test
    public void separateProcessWaitsForOsFileLock() throws Exception {
        File path = Files.createTempFile("balance-process-lock", ".lock").toFile();
        Process child = null;
        try (LedgerFileLock first = LedgerFileLock.acquire(path)) {
            String classpath = new File(LedgerLockProbe.class.getProtectionDomain()
                .getCodeSource().getLocation().toURI()).getPath()
                + File.pathSeparator + new File(LedgerFileLock.class.getProtectionDomain()
                .getCodeSource().getLocation().toURI()).getPath();
            child = new ProcessBuilder(new File(System.getProperty("java.home"), "bin/java").getPath(),
                "-cp", classpath, LedgerLockProbe.class.getName(), path.getPath())
                .redirectErrorStream(true).start();
            BufferedReader output = new BufferedReader(new InputStreamReader(child.getInputStream()));
            assertEquals("waiting", output.readLine());
            assertFalse(child.waitFor(100, TimeUnit.MILLISECONDS));
            first.close();
            assertTrue(child.waitFor(3, TimeUnit.SECONDS));
            assertEquals("acquired", output.readLine());
            assertEquals(0, child.exitValue());
        } finally {
            if (child != null && child.isAlive()) child.destroyForcibly();
            path.delete();
        }
    }

    @Test
    public void concurrentOwnersWaitAndReleaseIsIdempotent() throws Exception {
        File path = Files.createTempFile("balance-lock", ".lock").toFile();
        LedgerFileLock first = LedgerFileLock.acquire(path);
        CountDownLatch waiting = new CountDownLatch(1);
        CountDownLatch entered = new CountDownLatch(1);
        Thread second = new Thread(() -> {
            waiting.countDown();
            try (LedgerFileLock ignored = LedgerFileLock.acquire(path)) {
                entered.countDown();
            } catch (Exception error) { throw new AssertionError(error); }
        });
        second.start();
        assertTrue(waiting.await(2, TimeUnit.SECONDS));
        assertFalse(entered.await(100, TimeUnit.MILLISECONDS));
        first.close();
        first.close();
        assertTrue(entered.await(2, TimeUnit.SECONDS));
        second.join(2000);
        assertFalse(second.isAlive());
        path.delete();
    }

    @Test
    public void interruptedWaiterDoesNotLeakOrReleaseAnotherOwner() throws Exception {
        File path = Files.createTempFile("balance-lock", ".lock").toFile();
        LedgerFileLock first = LedgerFileLock.acquire(path);
        CountDownLatch waiting = new CountDownLatch(1);
        AtomicBoolean interrupted = new AtomicBoolean();
        Thread waiter = new Thread(() -> {
            waiting.countDown();
            try (LedgerFileLock ignored = LedgerFileLock.acquire(path)) {
                fail("Interrupted waiter must not acquire");
            } catch (InterruptedException expected) { interrupted.set(true); }
            catch (Exception error) { throw new AssertionError(error); }
        });
        waiter.start();
        assertTrue(waiting.await(2, TimeUnit.SECONDS));
        waiter.interrupt();
        waiter.join(2000);
        assertTrue(interrupted.get());
        first.close();
        try (LedgerFileLock after = LedgerFileLock.acquire(path)) {
            assertNotNull(after.token);
        }
        path.delete();
    }
}
