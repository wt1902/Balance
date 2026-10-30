package com.balance.runtime;

import java.io.File;

/** Separate JVM helper used to exercise the actual OS-level file lock. */
public final class LedgerLockProbe {
    public static void main(String[] args) throws Exception {
        System.out.println("waiting");
        System.out.flush();
        try (LedgerFileLock ignored = LedgerFileLock.acquire(new File(args[0]))) {
            System.out.println("acquired");
        }
    }
}
