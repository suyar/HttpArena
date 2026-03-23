package io.netty.util;

import java.util.function.Supplier;

/**
 * Shadow of Netty's LeakPresenceDetector that skips the stack-trace check,
 * allowing -XX:-StackTraceInThrowable to be used safely.
 */
public final class LeakPresenceDetector {
    private LeakPresenceDetector() {}

    public static <T> T staticInitializer(Supplier<T> supplier) {
        return supplier.get();
    }
}
