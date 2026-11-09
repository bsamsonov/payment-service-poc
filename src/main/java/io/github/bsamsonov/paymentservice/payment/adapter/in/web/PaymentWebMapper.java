package io.github.bsamsonov.paymentservice.payment.adapter.in.web;

import io.github.bsamsonov.paymentservice.payment.adapter.in.web.model.CreatePaymentRequest;
import io.github.bsamsonov.paymentservice.payment.adapter.in.web.model.Payment;
import io.github.bsamsonov.paymentservice.payment.adapter.in.web.model.PaymentStatus;
import io.github.bsamsonov.paymentservice.payment.application.CreatePaymentCommand;
import io.github.bsamsonov.paymentservice.payment.application.PaymentView;
import java.time.ZoneOffset;
import java.util.Map;
import org.jspecify.annotations.Nullable;

/** Maps the generated API types to the application's and back. */
final class PaymentWebMapper {

    // Refunds arrive in spec 006; until then nothing is ever refunded
    private static final long NOTHING_REFUNDED = 0;

    private PaymentWebMapper() {}

    static CreatePaymentCommand toCommand(CreatePaymentRequest request) {
        @Nullable Map<String, String> metadata = request.getMetadata();
        return new CreatePaymentCommand(
                request.getAmount(),
                request.getCurrency(),
                request.getPaymentMethodId(),
                request.getExternalReference(),
                request.getDescription(),
                metadata == null ? Map.of() : metadata);
    }

    static Payment toResponse(PaymentView view) {
        // The domain payment; Payment here is the generated response type
        var payment = view.payment();
        Payment response = new Payment(
                payment.id().value(),
                payment.amount().amount(),
                payment.amount().currency().getCurrencyCode(),
                payment.externalReference(),
                toResponse(payment.status()),
                NOTHING_REFUNDED,
                view.createdAt().atOffset(ZoneOffset.UTC),
                view.updatedAt().atOffset(ZoneOffset.UTC));
        response.setDescription(payment.description());
        // Absent optional fields are omitted (api/openapi.yaml); empty metadata counts as absent (AC-17)
        response.setMetadata(payment.metadata().isEmpty() ? null : payment.metadata());
        return response;
    }

    // Exhaustive without default: a new domain status fails the build here, not a request at run time
    private static PaymentStatus toResponse(io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus status) {
        return switch (status) {
            case PENDING -> PaymentStatus.PENDING;
            case PROCESSING -> PaymentStatus.PROCESSING;
            case SUCCEEDED -> PaymentStatus.SUCCEEDED;
            case FAILED -> PaymentStatus.FAILED;
            case PARTIALLY_REFUNDED -> PaymentStatus.PARTIALLY_REFUNDED;
            case REFUNDED -> PaymentStatus.REFUNDED;
        };
    }
}
