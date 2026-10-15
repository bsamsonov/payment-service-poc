package io.github.bsamsonov.paymentservice.payment.adapter.out.persistence;

import static org.assertj.core.api.Assertions.assertThat;

import io.github.bsamsonov.paymentservice.TestcontainersConfiguration;
import java.time.Instant;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;

/** Entities match the Flyway schema (ddl-auto=validate) and every column is written where the schema expects it. */
@Import(TestcontainersConfiguration.class)
@SpringBootTest
class PersistenceMappingIT {

    @Autowired
    private PaymentJpaRepository payments;

    @Autowired
    private PaymentEventJpaRepository events;

    @Autowired
    private ProviderAttemptJpaRepository attempts;

    @Autowired
    private JdbcTemplate jdbc;

    @Test
    void paymentMetadataRoundTripsAsJsonbAndAuditColumnsAreSet() {
        UUID id = UUID.randomUUID();
        payments.save(new PaymentEntity(
                id,
                1999,
                "USD",
                "pm_card_visa",
                "order-" + id,
                "Order 42",
                Map.of("orderId", "42", "channel", "web"),
                "PENDING",
                "a".repeat(64)));

        PaymentEntity loaded = payments.findById(id).orElseThrow();

        assertThat(loaded.getId()).isEqualTo(id);
        assertThat(loaded.getAmount()).isEqualTo(1999);
        assertThat(loaded.getCurrency()).isEqualTo("USD");
        assertThat(loaded.getPaymentMethodId()).isEqualTo("pm_card_visa");
        assertThat(loaded.getExternalReference()).isEqualTo("order-" + id);
        assertThat(loaded.getDescription()).isEqualTo("Order 42");
        assertThat(loaded.getMetadata()).containsExactlyInAnyOrderEntriesOf(Map.of("orderId", "42", "channel", "web"));
        assertThat(loaded.getStatus()).isEqualTo("PENDING");
        assertThat(loaded.getFailureCode()).isNull();
        assertThat(loaded.getRequestHash()).isEqualTo("a".repeat(64));
        assertThat(loaded.getCreatedAt()).isNotNull();
        assertThat(loaded.getUpdatedAt()).isNotNull();
        assertThat(loaded.getVersion()).isZero();
        assertThat(jdbc.queryForObject("select metadata ->> 'orderId' from payments where id = ?", String.class, id))
                .isEqualTo("42");
    }

    @Test
    void stateUpdateIsStoredAndBumpsTheVersion() {
        UUID id = UUID.randomUUID();
        PaymentEntity saved = payments.save(new PaymentEntity(
                id, 5000, "USD", "pm_card_chargeDeclined", "order-" + id, null, null, "PENDING", "c".repeat(64)));

        saved.updateState("FAILED", "card_declined");
        payments.save(saved);

        PaymentEntity loaded = payments.findById(id).orElseThrow();
        assertThat(loaded.getStatus()).isEqualTo("FAILED");
        assertThat(loaded.getFailureCode()).isEqualTo("card_declined");
        assertThat(loaded.getVersion()).isEqualTo(1);
    }

    @Test
    void journalEntitiesWriteEveryColumn() {
        UUID paymentId = UUID.randomUUID();
        payments.save(new PaymentEntity(
                paymentId, 1999, "USD", "pm_card_visa", "order-" + paymentId, null, null, "PENDING", "b".repeat(64)));
        String traceId = "0af7651916cd43dd8448eb211c80319c";
        Instant now = Instant.now();
        UUID eventId = UUID.randomUUID();
        events.save(new PaymentEventEntity(
                eventId,
                paymentId,
                1,
                "TRANSITION_REJECTED",
                "FAILED",
                "FAILED",
                "insufficient_funds",
                "conflicting_duplicate",
                "PROVIDER",
                "PROVIDER_RESPONSE",
                traceId,
                now,
                now));
        UUID attemptId = UUID.randomUUID();
        attempts.save(new ProviderAttemptEntity(
                attemptId, paymentId, 1, "DECLINED", (short) 402, "card_declined", "req_1", 120, traceId, now, now));

        assertThat(jdbc.queryForMap(
                        "select from_status, to_status, failure_code, reason_code, trace_id from payment_events"
                                + " where id = ?",
                        eventId))
                .containsEntry("from_status", "FAILED")
                .containsEntry("to_status", "FAILED")
                .containsEntry("failure_code", "insufficient_funds")
                .containsEntry("reason_code", "conflicting_duplicate")
                .containsEntry("trace_id", traceId);
        assertThat(jdbc.queryForMap(
                        "select outcome, provider_http_status, provider_code, provider_request_id,"
                                + " provider_duration_ms from provider_attempts where id = ?",
                        attemptId))
                .containsEntry("outcome", "DECLINED")
                .containsEntry("provider_http_status", 402) // the driver reads smallint as Integer
                .containsEntry("provider_code", "card_declined")
                .containsEntry("provider_request_id", "req_1")
                .containsEntry("provider_duration_ms", 120);
    }
}
