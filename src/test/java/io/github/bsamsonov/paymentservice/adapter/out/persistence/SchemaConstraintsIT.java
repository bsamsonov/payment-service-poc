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
        assertCheckViolation(() -> insertPayment(status, failureCode), "payments_failure_code_status");
    }

    @Test
    void providerAttemptWithAttemptFieldsIsAccepted() {
        UUID paymentId = insertPayment("PENDING", null);

        assertThatCode(() -> jdbc.update("""
                        insert into payment_events (id, payment_id, sequence_no, event_type, actor_type, source,
                            amount, currency, refunded_amount, attempt_no, outcome, provider_http_status,
                            provider_request_id, provider_duration_ms, occurred_at, recorded_at)
                        values (?, ?, 1, 'PROVIDER_ATTEMPT', 'SYSTEM', 'PROVIDER_RESPONSE', 1000, 'USD', 0,
                            1, 'SUCCEEDED', 200, 'req_1', 120, now(), now())
                        """, UUID.randomUUID(), paymentId)).doesNotThrowAnyException();
    }

    @ParameterizedTest(name = "{0} on a status change")
    @CsvSource({
        "attempt_no,           1",
        "outcome,              SUCCEEDED",
        "provider_http_status, 200",
        "provider_request_id,  req_1",
        "provider_duration_ms, 120"
    })
    void attemptFieldsAreOnlyAllowedOnProviderAttempts(String column, String value) {
        UUID paymentId = insertPayment("PENDING", null);

        assertCheckViolation(
                () -> jdbc.update(
                        "insert into payment_events (id, payment_id, sequence_no, event_type, to_status, actor_type,"
                                + " source, amount, currency, refunded_amount, occurred_at, recorded_at, " + column
                                + ") values (?, ?, 1, 'STATUS_CHANGED', 'PROCESSING', 'SYSTEM', 'API', 1000, 'USD', 0,"
                                + " now(), now(), ?)",
                        UUID.randomUUID(),
                        paymentId,
                        column.equals("outcome") || column.equals("provider_request_id") ? value : Long.valueOf(value)),
                "payment_events_attempt_fields_only_on_attempts");
    }

    private UUID insertPayment(String status, @Nullable String failureCode) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                insert into payments (id, amount, currency, payment_method_id, external_reference, status,
                    failure_code, refunded_amount, request_hash, last_event_seq, created_at, updated_at, version)
                values (?, 1000, 'USD', 'pm_card_visa', ?, ?, ?, 0, repeat('a', 64), 0, now(), now(), 0)
                """, id, "order-" + id, status, failureCode);
        return id;
    }

    private static void assertCheckViolation(Runnable statement, String constraint) {
        assertThatThrownBy(statement::run)
                .isInstanceOf(DataAccessException.class)
                .satisfies(e -> {
                    Throwable cause = NestedExceptionUtils.getMostSpecificCause(e);
                    assertThat(cause).isInstanceOf(SQLException.class);
                    assertThat(((SQLException) cause).getSQLState()).isEqualTo(CHECK_VIOLATION);
                    assertThat(cause.getMessage()).contains(constraint);
                });
    }
}
