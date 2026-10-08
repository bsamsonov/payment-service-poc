package io.github.bsamsonov.paymentservice.adapter.out.persistence;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.github.bsamsonov.paymentservice.TestcontainersConfiguration;
import java.sql.SQLException;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.core.NestedExceptionUtils;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;

@Import(TestcontainersConfiguration.class)
@SpringBootTest
class AppendOnlyJournalIT {

    private static final String INSUFFICIENT_PRIVILEGE = "42501";

    @Autowired
    private JdbcTemplate jdbc;

    // Journal rows can never be deleted and the database is shared by every test of the cached context:
    // keep the rows unique so other tests never match them.
    @BeforeEach
    void insertJournalRows() {
        UUID paymentId = UUID.randomUUID();
        jdbc.update("""
                insert into payments (id, amount, currency, payment_method_id, external_reference, status,
                    refunded_amount, request_hash, last_event_seq, created_at, updated_at, version)
                values (?, 1000, 'USD', 'pm_card_visa', ?, 'PENDING', 0, repeat('a', 64), 1, now(), now(), 0)
                """, paymentId, "order-" + paymentId);
        jdbc.update("""
                insert into payment_events (id, payment_id, sequence_no, event_type, to_status, actor_type, source,
                    amount, currency, refunded_amount, occurred_at, recorded_at)
                values (?, ?, 1, 'PAYMENT_CREATED', 'PENDING', 'CLIENT', 'API', 1000, 'USD', 0, now(), now())
                """, UUID.randomUUID(), paymentId);
        jdbc.update("""
                insert into rejected_requests (id, actor_type, http_method, path, http_status, problem_type,
                    occurred_at)
                values (?, 'CLIENT', 'POST', '/api/v1/payments', 400, '/problems/validation-error', now())
                """, UUID.randomUUID());
    }

    @ParameterizedTest(name = "{0} on {1}")
    @CsvSource({
        "UPDATE,   payment_events,    update payment_events set reason_code = 'x'",
        "DELETE,   payment_events,    delete from payment_events",
        "TRUNCATE, payment_events,    truncate payment_events",
        "UPDATE,   rejected_requests, update rejected_requests set path = '/x'",
        "DELETE,   rejected_requests, delete from rejected_requests",
        "TRUNCATE, rejected_requests, truncate rejected_requests"
    })
    @DisplayName("001/AC-12: the database rejects changes to journal rows")
    void journalsAreAppendOnly(String operation, String table, String sql) {
        assertThatThrownBy(() -> jdbc.execute(sql))
                .isInstanceOf(DataAccessException.class)
                .satisfies(e -> {
                    Throwable cause = NestedExceptionUtils.getMostSpecificCause(e);
                    assertThat(cause).isInstanceOf(SQLException.class);
                    assertThat(((SQLException) cause).getSQLState()).isEqualTo(INSUFFICIENT_PRIVILEGE);
                    assertThat(cause.getMessage()).contains(table, operation);
                });
    }
}
