package io.github.bsamsonov.paymentservice.payment.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doAnswer;

import io.github.bsamsonov.paymentservice.TestcontainersConfiguration;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentJournal;
import io.github.bsamsonov.paymentservice.payment.domain.BusinessRule;
import io.github.bsamsonov.paymentservice.payment.domain.EventType;
import io.github.bsamsonov.paymentservice.payment.domain.Payment;
import io.github.bsamsonov.paymentservice.payment.domain.PaymentEvent;
import io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus;
import io.github.bsamsonov.paymentservice.payment.domain.RuleViolation;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;

@Import(TestcontainersConfiguration.class)
@SpringBootTest
class CreatePaymentUseCaseIT {

    @Autowired
    private CreatePaymentUseCase createPayment;

    @MockitoSpyBean
    private PaymentJournal journal;

    @Autowired
    private JdbcTemplate jdbc;

    record EventRow(long sequenceNo, String type, @Nullable String from, String to, String actor, String source) {}

    record AttemptRow(
            int attemptNo,
            String outcome,
            @Nullable Integer httpStatus,
            @Nullable String providerRequestId,
            int durationMs,
            @Nullable String traceId) {}

    @Test
    @DisplayName("a charged payment is SUCCEEDED, journaled as created then changed, with its provider attempt")
    void createsAndChargesAPayment() {
        Payment payment = createPayment.create(command("pm_card_visa", Map.of("order", "42")));

        assertThat(payment.status()).isEqualTo(PaymentStatus.SUCCEEDED);
        assertThat(events(payment))
                .containsExactly(
                        new EventRow(1, "PAYMENT_CREATED", null, "PENDING", "CLIENT", "API"),
                        new EventRow(2, "STATUS_CHANGED", "PENDING", "SUCCEEDED", "PROVIDER", "PROVIDER_RESPONSE"));
        assertThat(attempts(payment)).singleElement().satisfies(attempt -> {
            assertThat(attempt.attemptNo()).isEqualTo(1);
            assertThat(attempt.outcome()).isEqualTo("SUCCEEDED");
            assertThat(attempt.httpStatus()).isEqualTo(200);
            assertThat(attempt.providerRequestId()).startsWith("fake_");
            assertThat(attempt.durationMs()).isNotNegative();
        });
    }

    @Test
    @DisplayName("the payment stores the hash of its canonical request; empty metadata hashes like none")
    void storesTheRequestHash() {
        CreatePaymentCommand command = command("pm_card_visa", Map.of());
        Payment payment = createPayment.create(command);

        Map<String, @Nullable Object> request = new HashMap<>();
        request.put("amount", 1999L);
        request.put("currency", "USD");
        request.put("paymentMethodId", "pm_card_visa");
        request.put("externalReference", command.externalReference());
        assertThat(jdbc.queryForObject(
                        "select request_hash from payments where id = ?",
                        String.class,
                        payment.id().value()))
                .isEqualTo(RequestHasher.hash(request));
    }

    @Test
    @DisplayName("the provider attempt commits with the status change: a failed event insert rolls both back")
    void writesTheProviderAttemptInTheStatusChangeTransaction() {
        doAnswer(invocation -> {
                    PaymentEvent event = invocation.getArgument(0);
                    if (event.type() == EventType.STATUS_CHANGED) {
                        throw new DataAccessResourceFailureException("event insert failed");
                    }
                    return invocation.callRealMethod();
                })
                .when(journal)
                .append(any(PaymentEvent.class));
        CreatePaymentCommand command = command("pm_card_visa", Map.of());

        assertThatThrownBy(() -> createPayment.create(command)).isInstanceOf(DataAccessResourceFailureException.class);

        UUID id = jdbc.queryForObject(
                "select id from payments where external_reference = ?", UUID.class, command.externalReference());
        assertThat(jdbc.queryForObject("select status from payments where id = ?", String.class, id))
                .isEqualTo("PENDING");
        assertThat(jdbc.queryForObject(
                        "select count(*) from provider_attempts where payment_id = ?", Integer.class, id))
                .isZero();
    }

    @Test
    @DisplayName("a request that breaks business rules lists every violation and creates no payment")
    void rejectsABusinessRuleViolationWithoutAPayment() {
        CreatePaymentCommand command =
                new CreatePaymentCommand(10, "EUR", "pm_card_visa", "order-" + UUID.randomUUID(), null, Map.of());

        assertThatThrownBy(() -> createPayment.create(command))
                .isInstanceOfSatisfying(
                        BusinessRuleViolation.class,
                        violation -> assertThat(violation.violations())
                                .containsExactly(new RuleViolation("currency", BusinessRule.CURRENCY_NOT_ALLOWED)));
        assertThat(jdbc.queryForObject(
                        "select count(*) from payments where external_reference = ?",
                        Integer.class,
                        command.externalReference()))
                .isZero();
    }

    private static CreatePaymentCommand command(String paymentMethodId, Map<String, String> metadata) {
        return new CreatePaymentCommand(1999, "USD", paymentMethodId, "order-" + UUID.randomUUID(), null, metadata);
    }

    private List<EventRow> events(Payment payment) {
        return jdbc.query(
                """
                select sequence_no, event_type, from_status, to_status, actor_type, source
                from payment_events where payment_id = ? order by sequence_no""",
                (rs, row) -> new EventRow(
                        rs.getLong("sequence_no"),
                        rs.getString("event_type"),
                        rs.getString("from_status"),
                        rs.getString("to_status"),
                        rs.getString("actor_type"),
                        rs.getString("source")),
                payment.id().value());
    }

    private List<AttemptRow> attempts(Payment payment) {
        return jdbc.query(
                """
                select attempt_no, outcome, provider_http_status, provider_request_id, provider_duration_ms, trace_id
                from provider_attempts where payment_id = ? order by attempt_no""",
                (rs, row) -> new AttemptRow(
                        rs.getInt("attempt_no"),
                        rs.getString("outcome"),
                        rs.getObject("provider_http_status", Integer.class),
                        rs.getString("provider_request_id"),
                        rs.getInt("provider_duration_ms"),
                        rs.getString("trace_id")),
                payment.id().value());
    }
}
