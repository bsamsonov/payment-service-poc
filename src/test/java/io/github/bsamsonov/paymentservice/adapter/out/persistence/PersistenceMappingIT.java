package io.github.bsamsonov.paymentservice.adapter.out.persistence;

import static org.assertj.core.api.Assertions.assertThat;

import io.github.bsamsonov.paymentservice.TestcontainersConfiguration;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;

/** Entities match the Flyway schema (ddl-auto=validate) and jsonb columns round-trip as real JSON. */
@Import(TestcontainersConfiguration.class)
@SpringBootTest
class PersistenceMappingIT {

    @Autowired
    private PaymentJpaRepository payments;

    @Autowired
    private PaymentEventJpaRepository events;

    @Autowired
    private RejectedRequestJpaRepository rejectedRequests;

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
                "order-42",
                "Order 42",
                Map.of("orderId", "42", "channel", "web"),
                "PENDING",
                "a".repeat(64)));

        PaymentEntity loaded = payments.findById(id).orElseThrow();

        assertThat(loaded.getId()).isEqualTo(id);
        assertThat(loaded.getAmount()).isEqualTo(1999);
        assertThat(loaded.getCurrency()).isEqualTo("USD");
        assertThat(loaded.getPaymentMethodId()).isEqualTo("pm_card_visa");
        assertThat(loaded.getExternalReference()).isEqualTo("order-42");
        assertThat(loaded.getDescription()).isEqualTo("Order 42");
        assertThat(loaded.getMetadata()).containsExactlyInAnyOrderEntriesOf(Map.of("orderId", "42", "channel", "web"));
        assertThat(loaded.getStatus()).isEqualTo("PENDING");
        assertThat(loaded.getRefundedAmount()).isZero();
        assertThat(loaded.getFailureCode()).isNull();
        assertThat(loaded.getRequestHash()).isEqualTo("a".repeat(64));
        assertThat(loaded.getLastEventSeq()).isZero();
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
                id, 5000, "USD", "pm_card_chargeDeclined", "order-44", null, null, "PENDING", "c".repeat(64)));

        saved.updateState("FAILED", "card_declined", 0, 2);
        payments.save(saved);

        PaymentEntity loaded = payments.findById(id).orElseThrow();
        assertThat(loaded.getStatus()).isEqualTo("FAILED");
        assertThat(loaded.getFailureCode()).isEqualTo("card_declined");
        assertThat(loaded.getLastEventSeq()).isEqualTo(2);
        assertThat(loaded.getVersion()).isEqualTo(1);
    }

    @Test
    void eventDetailsAndRejectedRequestErrorFieldsRoundTripAsJsonb() {
        UUID paymentId = UUID.randomUUID();
        payments.save(new PaymentEntity(
                paymentId, 1999, "USD", "pm_card_visa", "order-43", null, null, "PENDING", "b".repeat(64)));
        UUID eventId = UUID.randomUUID();
        Instant now = Instant.now();
        events.save(new PaymentEventEntity(
                eventId,
                paymentId,
                1,
                "TRANSITION_REJECTED",
                "SUCCEEDED",
                "FAILED",
                "PROVIDER",
                null,
                "PROVIDER_RESPONSE",
                "conflicting_duplicate",
                null,
                1999,
                "USD",
                0,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                now,
                now,
                Map.of("current", "card_declined", "attempted", "insufficient_funds")));
        UUID rejectedId = UUID.randomUUID();
        rejectedRequests.save(new RejectedRequestEntity(
                rejectedId,
                null,
                "CLIENT",
                null,
                "POST",
                "/api/v1/payments",
                400,
                "/problems/validation-error",
                List.of(Map.of("field", "amount", "rule", "NotNull")),
                "order-43",
                now));

        assertThat(events.findById(eventId).orElseThrow().getDetails())
                .containsEntry("attempted", "insufficient_funds");
        assertThat(rejectedRequests.findById(rejectedId).orElseThrow().getErrorFields())
                .containsExactly(Map.of("field", "amount", "rule", "NotNull"));
        assertThat(jdbc.queryForObject(
                        "select error_fields -> 0 ->> 'rule' from rejected_requests where id = ?",
                        String.class,
                        rejectedId))
                .isEqualTo("NotNull");
    }
}
