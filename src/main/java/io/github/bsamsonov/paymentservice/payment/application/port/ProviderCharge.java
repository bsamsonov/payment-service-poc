package io.github.bsamsonov.paymentservice.payment.application.port;

import io.github.bsamsonov.paymentservice.payment.domain.ProviderOutcome;
import java.util.List;

/** The calls made to charge a payment, in order; the last call's outcome is the result of the charge. */
public record ProviderCharge(List<ProviderCall> calls) {

    public ProviderCharge {
        if (calls.isEmpty()) {
            throw new IllegalArgumentException("a charge makes at least one call");
        }
        calls = List.copyOf(calls);
    }

    public ProviderOutcome outcome() {
        return calls.getLast().outcome();
    }
}
