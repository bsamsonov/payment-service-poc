package io.github.bsamsonov.paymentservice.payment.adapter.out.persistence;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;

import io.github.bsamsonov.paymentservice.TestcontainersConfiguration;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentJournal;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentRepository;
import io.github.bsamsonov.paymentservice.payment.domain.ActorType;
import io.github.bsamsonov.paymentservice.payment.domain.EventOrigin;
import io.github.bsamsonov.paymentservice.payment.domain.EventSource;
import io.github.bsamsonov.paymentservice.payment.domain.EventType;
import io.github.bsamsonov.paymentservice.payment.domain.FailureCode;
import io.github.bsamsonov.paymentservice.payment.domain.Money;
import io.github.bsamsonov.paymentservice.payment.domain.Payment;
import io.github.bsamsonov.paymentservice.payment.domain.PaymentEvent;
import io.github.bsamsonov.paymentservice.payment.domain.PaymentId;
import io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus;
import io.github.bsamsonov.paymentservice.payment.domain.ProviderAttempt;
import io.github.bsamsonov.paymentservice.payment.domain.ProviderOutcome;
import java.time.Duration;
import java.time.Instant;
import java.util.Arrays;
import java.util.Currency;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;

/**
 * The Java enums are the source of the coded values; every constant, as the adapter writes it, must be accepted by its
 * database domain or check. A constant added in Java without a migration fails here.
 */
@Import(TestcontainersConfiguration.class)
@SpringBootTest
class CodedValueDomainsIT {

    /** One outcome of each kind; the test below keeps the list complete. */
    private static final List<ProviderOutcome> OUTCOMES = List.of(
            new ProviderOutcome.Succeeded(),
            new ProviderOutcome.Declined(FailureCode.CARD_DECLINED, "card_declined"),
            new ProviderOutcome.Rejected(),
            new ProviderOutcome.Unknown());

    @Autowired
    private JdbcTemplate jdbc;

    @Autowired
    private PaymentRepository payments;

    @Autowired
    private PaymentJournal journal;

    @ParameterizedTest
    @EnumSource(PaymentStatus.class)
    @DisplayName("every payment status is accepted by the payment_status domain")
    void paymentStatusesBelongToTheDomain(PaymentStatus status) {
        assertAccepted(DomainCodes.status(status), "payment_status");
    }

    @ParameterizedTest
    @EnumSource(FailureCode.class)
    @DisplayName("every failure code is accepted by the failure_code domain")
    void failureCodesBelongToTheDomain(FailureCode code) {
        assertAccepted(DomainCodes.failureCode(code), "failure_code");
    }

    @ParameterizedTest
    @EnumSource(EventType.class)
    @DisplayName("every event type is accepted by the payment_event_type domain")
    void eventTypesBelongToTheDomain(EventType type) {
        assertAccepted(DomainCodes.eventType(type), "payment_event_type");
    }

    @Test
    @DisplayName("every kind of provider outcome is written to provider_attempts")
    void providerOutcomesBelongToTheDomain() {
        assertThat(OUTCOMES.stream().map(Object::getClass))
                .containsExactlyInAnyOrder(ProviderOutcome.class.getPermittedSubclasses());
        PaymentId paymentId = storedPayment();

        for (int i = 0; i < OUTCOMES.size(); i++) {
            ProviderAttempt attempt = new ProviderAttempt(
                    UUID.randomUUID(),
                    paymentId,
                    i + 1,
                    OUTCOMES.get(i),
                    200,
                    null,
                    "req_" + i,
                    Duration.ofMillis(120),
                    null,
                    Instant.now());
            assertThatCode(() -> journal.append(attempt)).doesNotThrowAnyException();
        }
        assertThat(jdbc.queryForList(
                        "select outcome from provider_attempts where payment_id = ? order by attempt_no",
                        String.class,
                        paymentId.value()))
                .containsExactly("SUCCEEDED", "DECLINED", "REJECTED", "UNKNOWN");
    }

    @Test
    @DisplayName("every event origin is an allowed actor/source pair, and the origins use every actor and source")
    void eventOriginsAreAllowedPairs() {
        assertThat(Arrays.stream(EventOrigin.values()).map(EventOrigin::actorType))
                .containsExactlyInAnyOrder(ActorType.values());
        assertThat(Arrays.stream(EventOrigin.values()).map(EventOrigin::source).distinct())
                .containsExactlyInAnyOrder(EventSource.values());
        PaymentId paymentId = storedPayment();

        for (EventOrigin origin : EventOrigin.values()) {
            PaymentEvent event = new PaymentEvent(
                    UUID.randomUUID(),
                    paymentId,
                    origin.ordinal() + 1L,
                    origin.ordinal() == 0 ? EventType.PAYMENT_CREATED : EventType.TRANSITION_REJECTED,
                    origin.ordinal() == 0 ? null : PaymentStatus.PENDING,
                    PaymentStatus.PENDING,
                    null,
                    null,
                    origin,
                    null,
                    Instant.now());
            assertThatCode(() -> journal.append(event)).doesNotThrowAnyException();
        }
    }

    private void assertAccepted(String value, String domain) {
        assertThat(jdbc.queryForObject("select cast(? as " + domain + ")", String.class, value))
                .isEqualTo(value);
    }

    private PaymentId storedPayment() {
        PaymentId id = new PaymentId(UUID.randomUUID());
        payments.add(Payment.create(
                id,
                new Money(1999, Currency.getInstance("USD")),
                "pm_card_visa",
                "order-" + id,
                null,
                Map.of(),
                "a".repeat(64)));
        return id;
    }
}
