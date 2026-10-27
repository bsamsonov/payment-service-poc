package io.github.bsamsonov.paymentservice.payment.domain;

import org.jspecify.annotations.Nullable;

/** Result of charging a payment at the provider (spec 001, Flow). */
public sealed interface ProviderOutcome {

    /** Charged. */
    record Succeeded() implements ProviderOutcome {}

    /** A definite refusal (bank decline, 3DS required, invalid payment method); {@code providerCode} is never shown. */
    record Declined(FailureCode code, @Nullable String providerCode) implements ProviderOutcome {

        public Declined {
            if (code == FailureCode.PROVIDER_ERROR) {
                throw new IllegalArgumentException("a decline needs a decline code, not " + code);
            }
        }
    }

    /** The provider definitely did not execute the request. */
    record Rejected() implements ProviderOutcome {}

    /** Timeout, connection loss or 5xx: money may have moved. */
    record Unknown() implements ProviderOutcome {}
}
