package io.github.bsamsonov.paymentservice.payment.application;

import java.util.Map;
import org.jspecify.annotations.Nullable;

/** A request to create a payment that has passed the schema checks; the business rules are checked by the use case. */
public record CreatePaymentCommand(
        long amount,
        String currency,
        String paymentMethodId,
        String externalReference,
        @Nullable String description,
        Map<String, String> metadata) {

    public CreatePaymentCommand {
        metadata = Map.copyOf(metadata);
    }
}
