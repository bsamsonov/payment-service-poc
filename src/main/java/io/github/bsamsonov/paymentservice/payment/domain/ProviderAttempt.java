package io.github.bsamsonov.paymentservice.payment.domain;

import java.time.Duration;
import java.time.Instant;
import java.util.UUID;
import org.jspecify.annotations.Nullable;

/** One call to the payment provider, as recorded in {@code provider_attempts}. */
@SuppressWarnings({"TooManyParameters", "PMD.ExcessiveParameterList"}) // one component per log column
public record ProviderAttempt(
        UUID id,
        PaymentId paymentId,
        int attemptNo,
        ProviderOutcome outcome,
        @Nullable Integer providerHttpStatus,
        @Nullable String providerCode,
        @Nullable String providerRequestId,
        Duration duration,
        @Nullable String traceId,
        Instant startedAt) {}
