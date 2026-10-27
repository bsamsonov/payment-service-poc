package io.github.bsamsonov.paymentservice.payment.application;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Map;
import java.util.TreeMap;
import org.jspecify.annotations.Nullable;

/**
 * SHA-256 of the canonical form of a request (AC-17): JSON with keys sorted at every level, no whitespace, absent and
 * null fields omitted, strings escaped as in RFC 8785. Spec 002 compares it to detect "same idempotency key, different
 * request". Written by hand because the application layer does not use Jackson.
 */
final class RequestHasher {

    private RequestHasher() {}

    /** Lowercase hex SHA-256 of {@link #canonicalJson}; values are strings, integers or nested maps. */
    static String hash(Map<String, ? extends @Nullable Object> request) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                    .digest(canonicalJson(request).getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("every JVM provides SHA-256", e);
        }
    }

    static String canonicalJson(Map<String, ? extends @Nullable Object> request) {
        StringBuilder json = new StringBuilder();
        writeObject(json, request);
        return json.toString();
    }

    private static void writeObject(StringBuilder json, Map<?, ? extends @Nullable Object> object) {
        // String order is UTF-16 code unit order, as RFC 8785 requires
        Map<String, Object> sorted = new TreeMap<>();
        object.forEach((key, value) -> {
            if (value != null) {
                sorted.put((String) key, value);
            }
        });
        json.append('{');
        String separator = "";
        for (Map.Entry<String, Object> field : sorted.entrySet()) {
            json.append(separator);
            writeString(json, field.getKey());
            json.append(':');
            writeValue(json, field.getValue());
            separator = ",";
        }
        json.append('}');
    }

    private static void writeValue(StringBuilder json, Object value) {
        switch (value) {
            case String text -> writeString(json, text);
            case Long number -> json.append(number);
            case Integer number -> json.append(number);
            case Map<?, ?> object -> writeObject(json, object);
            default -> throw new IllegalArgumentException("unsupported request value type: " + value.getClass());
        }
    }

    private static void writeString(StringBuilder json, String text) {
        json.append('"');
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            switch (c) {
                case '"' -> json.append("\\\"");
                case '\\' -> json.append("\\\\");
                case '\b' -> json.append("\\b");
                case '\f' -> json.append("\\f");
                case '\n' -> json.append("\\n");
                case '\r' -> json.append("\\r");
                case '\t' -> json.append("\\t");
                default -> {
                    if (c < 0x20) {
                        json.append(String.format("\\u%04x", (int) c));
                    } else {
                        json.append(c);
                    }
                }
            }
        }
        json.append('"');
    }
}
