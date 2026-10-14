package io.github.bsamsonov.paymentservice.adapter.out.persistence;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.github.bsamsonov.paymentservice.TestcontainersConfiguration;
import java.sql.SQLException;
import java.util.UUID;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.core.NestedExceptionUtils;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;

/** Invariants that the schema enforces itself, because the journal rows can never be fixed after insert. */
@Import(TestcontainersConfiguration.class)
@SpringBootTest
class SchemaConstraintsIT {

    private static final String CHECK_VIOLATION = "23514";

    private static final String UNIQUE_VIOLATION = "23505";

    @Autowired
    private JdbcTemplate jdbc;

    @ParameterizedTest(name = "status {0}, failure_code {1}")
    @CsvSource({"FAILED, card_declined", "PENDING,", "SUCCEEDED,"})
    void failureCodeMatchingTheStatusIsAccepted(String status, @Nullable String failureCode) {
        assertThatCode(() -> insertPayment(status, failureCode)).doesNotThrowAnyException();
    }

    @ParameterizedTest(name = "status {0}, failure_code {1}")
    @CsvSource({"FAILED,", "PENDING, card_declined", "SUCCEEDED, provider_error"})
    void failureCodeIsSetIfAndOnlyIfThePaymentFailed(String status, @Nullable String failureCode) {
        assertViolation(() -> insertPayment(status, failureCode), CHECK_VIOLATION, "payments_failure_code_status");
    }

    @ParameterizedTest(name = "status {0}, failure_code {1}")
    @CsvSource({"DONE,, payment_status_values", "FAILED, card_stolen, failure_code_values"})
    void codedValuesMustBelongToTheirDomain(String status, @Nullable String failureCode, String constraint) {
        assertViolation(() -> insertPayment(status, failureCode), CHECK_VIOLATION, constraint);
    }

    @Test
    void eventsWithAValidActorAndChannelAreAccepted() {
        UUID paymentId = insertPayment("PENDING", null);

        assertThatCode(() -> {
                    insertEvent(paymentId, 1, "PAYMENT_CREATED", null, "PENDING", null, "CLIENT", "API");
                    insertEvent(
                            paymentId,
                            2,
                            "STATUS_CHANGED",
                            "PENDING",
                            "FAILED",
                            "card_declined",
                            "PROVIDER",
                            "PROVIDER_RESPONSE");
                })
                .doesNotThrowAnyException();
    }

    @Test
    void anActorCanOnlyActThroughItsOwnChannel() {
        UUID paymentId = insertPayment("PENDING", null);

        assertViolation(
                () -> insertEvent(
                        paymentId, 1, "PAYMENT_CREATED", null, "PENDING", null, "CLIENT", "PROVIDER_RESPONSE"),
                CHECK_VIOLATION,
                "payment_events_actor_source");
    }

    @Test
    void aSequenceNumberIsTakenOncePerPayment() {
        UUID paymentId = insertPayment("PENDING", null);
        insertEvent(paymentId, 1, "PAYMENT_CREATED", null, "PENDING", null, "CLIENT", "API");

        assertViolation(
                () -> insertEvent(
                        paymentId, 1, "STATUS_CHANGED", "PENDING", "SUCCEEDED", null, "PROVIDER", "PROVIDER_RESPONSE"),
                UNIQUE_VIOLATION,
                "payment_events_sequence_unique");
    }

    @ParameterizedTest(name = "{0} {1} -> {2}, failure_code {3}")
    @CsvSource({
        "PAYMENT_CREATED,     PENDING, PENDING,,               payment_events_from_status_present",
        "STATUS_CHANGED,      ,        SUCCEEDED,,             payment_events_from_status_present",
        "STATUS_CHANGED,      PENDING, FAILED,,                payment_events_failed_has_code",
        "STATUS_CHANGED,      PENDING, SUCCEEDED, card_declined, payment_events_failure_code_status",
        "TRANSITION_REJECTED, FAILED,  SUCCEEDED, card_declined, payment_events_failure_code_status"
    })
    void eventFieldsMatchTheEventType(
            String eventType,
            @Nullable String fromStatus,
            String toStatus,
            @Nullable String failureCode,
            String constraint) {
        UUID paymentId = insertPayment("PENDING", null);

        assertViolation(
                () -> insertEvent(
                        paymentId, 1, eventType, fromStatus, toStatus, failureCode, "PROVIDER", "PROVIDER_RESPONSE"),
                CHECK_VIOLATION,
                constraint);
    }

    @Test
    void traceIdMustBeAW3cTraceId() {
        UUID paymentId = insertPayment("PENDING", null);

        assertViolation(
                () -> jdbc.update("""
                        insert into provider_attempts (id, payment_id, attempt_no, outcome, provider_duration_ms,
                            trace_id, occurred_at, recorded_at)
                        values (?, ?, 1, 'SUCCEEDED', 120, 'not-a-trace-id', now(), now())
                        """, UUID.randomUUID(), paymentId),
                CHECK_VIOLATION,
                "provider_attempts_trace_id_format");
    }

    private UUID insertPayment(String status, @Nullable String failureCode) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                insert into payments (id, amount, currency, payment_method_id, external_reference, status,
                    failure_code, request_hash, created_at, updated_at, version)
                values (?, 1000, 'USD', 'pm_card_visa', ?, ?, ?, repeat('a', 64), now(), now(), 0)
                """, id, "order-" + id, status, failureCode);
        return id;
    }

    @SuppressWarnings("TooManyParameters") // one parameter per varied column
    private void insertEvent(
            UUID paymentId,
            long sequenceNo,
            String eventType,
            @Nullable String fromStatus,
            String toStatus,
            @Nullable String failureCode,
            String actorType,
            String source) {
        jdbc.update(
                """
                insert into payment_events (id, payment_id, sequence_no, event_type, from_status, to_status,
                    failure_code, actor_type, source, occurred_at, recorded_at)
                values (?, ?, ?, ?, ?, ?, ?, ?, ?, now(), now())
                """,
                UUID.randomUUID(),
                paymentId,
                sequenceNo,
                eventType,
                fromStatus,
                toStatus,
                failureCode,
                actorType,
                source);
    }

    private static void assertViolation(Runnable statement, String sqlState, String constraint) {
        assertThatThrownBy(statement::run)
                .isInstanceOf(DataAccessException.class)
                .satisfies(e -> {
                    Throwable cause = NestedExceptionUtils.getMostSpecificCause(e);
                    assertThat(cause).isInstanceOf(SQLException.class);
                    assertThat(((SQLException) cause).getSQLState()).isEqualTo(sqlState);
                    assertThat(cause.getMessage()).contains(constraint);
                });
    }
}
