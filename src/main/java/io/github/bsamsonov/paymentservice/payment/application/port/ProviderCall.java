package io.github.bsamsonov.paymentservice.payment.application.port;

import io.github.bsamsonov.paymentservice.payment.domain.ProviderOutcome;
import java.time.Duration;
import java.time.Instant;
import org.jspecify.annotations.Nullable;

/** One call to the provider as the provider adapter saw it; the use case turns it into a {@code ProviderAttempt}. */
public record ProviderCall(
        ProviderOutcome outcome,
        @Nullable Integer httpStatus,
        @Nullable String providerCode,
        @Nullable String providerRequestId,
        Duration duration,
        Instant startedAt) {}
