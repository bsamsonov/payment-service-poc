package io.github.bsamsonov.paymentservice.payment.adapter.out.provider.fake;

import io.github.bsamsonov.paymentservice.payment.application.port.PaymentProvider;
import io.github.bsamsonov.paymentservice.payment.application.port.ProviderCall;
import io.github.bsamsonov.paymentservice.payment.application.port.ProviderCharge;
import io.github.bsamsonov.paymentservice.payment.domain.Money;
import io.github.bsamsonov.paymentservice.payment.domain.PaymentId;
import io.github.bsamsonov.paymentservice.payment.domain.ProviderOutcome;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.UUID;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

/**
 * The fake provider of spec 001: one call per charge, the outcome chosen by the payment method id. Every id charges
 * successfully for now; the declining and failing ids of the spec's table come with their responses.
 */
@Component
@ConditionalOnProperty(name = "payments.provider", havingValue = "fake")
class FakePaymentProvider implements PaymentProvider {

    private final Clock clock;

    FakePaymentProvider(Clock clock) {
        this.clock = clock;
    }

    @Override
    public ProviderCharge charge(PaymentId paymentId, Money amount, String paymentMethodId) {
        Instant startedAt = Instant.now(clock);
        ProviderOutcome outcome = new ProviderOutcome.Succeeded();
        return new ProviderCharge(List.of(new ProviderCall(
                outcome,
                200,
                null,
                "fake_" + UUID.randomUUID(),
                Duration.between(startedAt, Instant.now(clock)),
                startedAt)));
    }
}
