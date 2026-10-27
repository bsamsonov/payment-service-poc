package io.github.bsamsonov.paymentservice.payment.application;

import static org.assertj.core.api.Assertions.assertThat;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.Map;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

class RequestHasherTest {

    @Test
    @DisplayName("001/AC-17: the canonical form has sorted keys at every level and no whitespace")
    void writesCanonicalJson() {
        Map<String, Object> metadata = new LinkedHashMap<>();
        metadata.put("orderId", "42");
        metadata.put("channel", "web");
        Map<String, Object> request = new LinkedHashMap<>();
        request.put("paymentMethodId", "pm_card_visa");
        request.put("amount", 1999L);
        request.put("metadata", metadata);
        request.put("currency", "USD");

        assertThat(RequestHasher.canonicalJson(request))
                .isEqualTo(
                        "{\"amount\":1999,\"currency\":\"USD\","
                                + "\"metadata\":{\"channel\":\"web\",\"orderId\":\"42\"},\"paymentMethodId\":\"pm_card_visa\"}");
    }

    @Test
    @DisplayName("001/AC-17: the hash is the lowercase hex SHA-256 of the canonical form")
    void hashesCanonicalJson() throws NoSuchAlgorithmException {
        Map<String, Object> request = Map.of("amount", 1999L, "currency", "USD");

        byte[] digest = MessageDigest.getInstance("SHA-256")
                .digest("{\"amount\":1999,\"currency\":\"USD\"}".getBytes(StandardCharsets.UTF_8));
        assertThat(RequestHasher.hash(request)).isEqualTo(HexFormat.of().formatHex(digest));
    }

    @Test
    @DisplayName("001/AC-17: requests differing only in key order, also in nested metadata, have the same hash")
    void keyOrderDoesNotChangeTheHash() {
        Map<String, Object> first = new LinkedHashMap<>();
        first.put("amount", 1999L);
        first.put("currency", "USD");
        first.put("metadata", linked("a", "1", "b", "2"));
        Map<String, Object> second = new LinkedHashMap<>();
        second.put("metadata", linked("b", "2", "a", "1"));
        second.put("currency", "USD");
        second.put("amount", 1999L);

        assertThat(RequestHasher.hash(first)).isEqualTo(RequestHasher.hash(second));
    }

    @Test
    @DisplayName("001/AC-17: a different value in any field, also in nested metadata, gives a different hash")
    void differentValueChangesTheHash() {
        Map<String, Object> base = Map.of("amount", 1999L, "currency", "USD", "metadata", Map.of("a", "1"));

        assertThat(RequestHasher.hash(base))
                .isNotEqualTo(
                        RequestHasher.hash(Map.of("amount", 2000L, "currency", "USD", "metadata", Map.of("a", "1"))))
                .isNotEqualTo(
                        RequestHasher.hash(Map.of("amount", 1999L, "currency", "EUR", "metadata", Map.of("a", "1"))))
                .isNotEqualTo(
                        RequestHasher.hash(Map.of("amount", 1999L, "currency", "USD", "metadata", Map.of("a", "2"))));
    }

    @Test
    @DisplayName("an absent field and a null field are the same request")
    void nullFieldIsOmitted() {
        Map<String, Object> withNull = new HashMap<>();
        withNull.put("amount", 1999L);
        withNull.put("description", null);

        assertThat(RequestHasher.canonicalJson(withNull)).isEqualTo("{\"amount\":1999}");
    }

    @Test
    @DisplayName("strings are escaped as in RFC 8785: quote, backslash and control characters; other text as is")
    void escapesStrings() {
        assertThat(RequestHasher.canonicalJson(Map.of("d", "a\"b\\c\nd\u0001é€")))
                .isEqualTo("{\"d\":\"a\\\"b\\\\c\\nd\\u0001é€\"}");
    }

    private static Map<String, Object> linked(String k1, String v1, String k2, String v2) {
        Map<String, Object> map = new LinkedHashMap<>();
        map.put(k1, v1);
        map.put(k2, v2);
        return map;
    }
}
