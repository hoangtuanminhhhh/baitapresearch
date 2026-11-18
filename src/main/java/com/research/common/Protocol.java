package com.research.common;

/**
 * Hang so protocol dung chung cho Server va Load generator.
 * Frame (big-endian): [4 byte N][8 byte requestId][N-8 byte payload], N = do dai body = 8 + payload.
 */
public final class Protocol {
    public static final int HEADER_BYTES = 4;        // truong do dai
    public static final int ID_BYTES = 8;            // requestId
    public static final int MAX_BODY = 64 * 1024;    // gioi han body; vuot => server dong connection

    private Protocol() { }
}
