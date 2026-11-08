package io.github.bsamsonov.paymentservice.payment.adapter.in.web;

import static org.assertj.core.api.Assertions.assertThat;

import io.github.bsamsonov.paymentservice.TestcontainersConfiguration;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.List;
import java.util.UUID;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.SpringBootTest.WebEnvironment;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.context.annotation.Import;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.web.servlet.client.EntityExchangeResult;
import org.springframework.test.web.servlet.client.RestTestClient;

/** {@code POST /api/v1/payments} over HTTP against a real server and PostgreSQL. */
@Import(TestcontainersConfiguration.class)
@SpringBootTest(webEnvironment = WebEnvironment.RANDOM_PORT)
class CreatePaymentIT {

    private static final String PAYMENTS = "/api/v1/payments";

    @LocalServerPort
    private int port;

    @Autowired
    private JdbcTemplate jdbc;

    private RestTestClient client;

    record EventRow(long sequenceNo, String type, @Nullable String from, String to) {}

    record AttemptRow(
            int attemptNo,
            String outcome,
            @Nullable Integer httpStatus,
            @Nullable String providerCode,
            @Nullable String providerRequestId,
            int durationMs) {}

    @BeforeEach
    void setUp() {
        client = RestTestClient.bindToServer()
                .baseUrl("http://localhost:" + port)
                .build();
    }

    @Test
    @DisplayName("001/AC-1: a charged card returns 201 with Location and the SUCCEEDED payment, journaled")
    void chargedCardReturnsCreated() {
        String reference = reference();

        EntityExchangeResult<byte[]> result = client.post()
                .uri(PAYMENTS)
                .contentType(MediaType.APPLICATION_JSON)
                .body("""
                        {"amount":1999,"currency":"USD","paymentMethodId":"pm_card_visa",\
                        "externalReference":"%s","description":"Order 42","metadata":{"order":"42"}}""".formatted(reference))
                .exchange()
                .expectStatus()
                .isCreated()
                .expectHeader()
                .contentType(MediaType.APPLICATION_JSON)
                .expectBody()
                .jsonPath("$.amount")
                .isEqualTo(1999)
                .jsonPath("$.currency")
                .isEqualTo("USD")
                .jsonPath("$.externalReference")
                .isEqualTo(reference)
                .jsonPath("$.description")
                .isEqualTo("Order 42")
                .jsonPath("$.metadata.order")
                .isEqualTo("42")
                .jsonPath("$.status")
                .isEqualTo("SUCCEEDED")
                .jsonPath("$.refundedAmount")
                .isEqualTo(0)
                .jsonPath("$.createdAt")
                .isNotEmpty()
                .jsonPath("$.updatedAt")
                .isNotEmpty()
                .jsonPath("$.failure")
                .doesNotExist()
                .jsonPath("$.paymentMethodId")
                .doesNotExist()
                .returnResult();

        UUID id = idOf(reference);
        assertThat(result.getResponseHeaders().getFirst(HttpHeaders.LOCATION)).isEqualTo(PAYMENTS + "/" + id);
        assertThat(new String(result.getResponseBodyContent(), StandardCharsets.UTF_8))
                .contains("\"id\":\"" + id + "\"");
        assertThat(events(id))
                .containsExactly(
                        new EventRow(1, "PAYMENT_CREATED", null, "PENDING"),
                        new EventRow(2, "STATUS_CHANGED", "PENDING", "SUCCEEDED"));
    }

    @Test
    @DisplayName("001/AC-15: the provider attempt is recorded with its outcome, HTTP status, request id and duration")
    void recordsTheProviderAttempt() {
        String reference = reference();

        create(request(reference, "pm_card_visa"));

        List<AttemptRow> attempts = attempts(idOf(reference));
        assertThat(attempts).singleElement().satisfies(attempt -> {
            assertThat(attempt.attemptNo()).isEqualTo(1);
            assertThat(attempt.outcome()).isEqualTo("SUCCEEDED");
            assertThat(attempt.httpStatus()).isEqualTo(200);
            assertThat(attempt.providerCode()).isNull();
            assertThat(attempt.providerRequestId()).startsWith("fake_");
            assertThat(attempt.durationMs()).isNotNegative();
        });
    }

    @Test
    @DisplayName(
            "001/AC-17: the payment stores the hash of the canonical request; key order and whitespace do not count")
    void storesTheCanonicalRequestHash() throws NoSuchAlgorithmException {
        String reference = reference();

        create("""
                {"amount":1999,"currency":"USD","paymentMethodId":"pm_card_visa",\
                "externalReference":"%s","metadata":{"a":"1","b":"2"}}""".formatted(reference));
        create("""
                {
                  "metadata" : { "b" : "2", "a" : "1" },
                  "externalReference" : "%s",
                  "paymentMethodId" : "pm_card_visa", "currency" : "USD", "amount" : 1999
                }""".formatted(reference));
        create("""
                {"amount":2000,"currency":"USD","paymentMethodId":"pm_card_visa",\
                "externalReference":"%s","metadata":{"a":"1","b":"2"}}""".formatted(reference));

        // The canonical form: keys sorted at every level, no whitespace
        String canonical = "{\"amount\":%d,\"currency\":\"USD\",\"externalReference\":\"%s\","
                + "\"metadata\":{\"a\":\"1\",\"b\":\"2\"},\"paymentMethodId\":\"pm_card_visa\"}";
        String hash = sha256(canonical.formatted(1999, reference));
        assertThat(jdbc.queryForList(
                        "select request_hash from payments where external_reference = ? order by id",
                        String.class,
                        reference))
                .containsExactly(hash, hash, sha256(canonical.formatted(2000, reference)));
    }

    private void create(String body) {
        client.post()
                .uri(PAYMENTS)
                .contentType(MediaType.APPLICATION_JSON)
                .body(body)
                .exchange()
                .expectStatus()
                .isCreated();
    }

    private static String request(String reference, String paymentMethodId) {
        return """
                {"amount":1999,"currency":"USD","paymentMethodId":"%s","externalReference":"%s"}""".formatted(paymentMethodId, reference);
    }

    private static String reference() {
        return "order-" + UUID.randomUUID();
    }

    private static String sha256(String text) throws NoSuchAlgorithmException {
        return HexFormat.of()
                .formatHex(MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8)));
    }

    private UUID idOf(String reference) {
        return jdbc.queryForList("select id from payments where external_reference = ?", UUID.class, reference)
                .getFirst();
    }

    private List<EventRow> events(UUID id) {
        return jdbc.query(
                "select sequence_no, event_type, from_status, to_status from payment_events where payment_id = ?"
                        + " order by sequence_no",
                (rs, row) -> new EventRow(
                        rs.getLong("sequence_no"),
                        rs.getString("event_type"),
                        rs.getString("from_status"),
                        rs.getString("to_status")),
                id);
    }

    private List<AttemptRow> attempts(UUID id) {
        return jdbc.query(
                """
                select attempt_no, outcome, provider_http_status, provider_code, provider_request_id, provider_duration_ms
                from provider_attempts where payment_id = ? order by attempt_no""",
                (rs, row) -> new AttemptRow(
                        rs.getInt("attempt_no"),
                        rs.getString("outcome"),
                        rs.getObject("provider_http_status", Integer.class),
                        rs.getString("provider_code"),
                        rs.getString("provider_request_id"),
                        rs.getInt("provider_duration_ms")),
                id);
    }
}
