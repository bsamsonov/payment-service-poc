package io.github.bsamsonov.paymentservice.payment.adapter.in.web;

import io.github.bsamsonov.paymentservice.payment.adapter.in.web.api.PaymentsApi;
import io.github.bsamsonov.paymentservice.payment.adapter.in.web.model.CreatePaymentRequest;
import io.github.bsamsonov.paymentservice.payment.adapter.in.web.model.Payment;
import io.github.bsamsonov.paymentservice.payment.application.CreatePaymentUseCase;
import io.github.bsamsonov.paymentservice.payment.application.PaymentView;
import java.net.URI;
import java.util.List;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.ErrorResponseException;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.util.UriComponentsBuilder;

/** The payments endpoints of {@code api/openapi.yaml}. */
@RestController
class PaymentsController implements PaymentsApi {

    private final CreatePaymentUseCase createPayment;

    PaymentsController(CreatePaymentUseCase createPayment) {
        this.createPayment = createPayment;
    }

    @Override
    public ResponseEntity<Payment> createPayment(CreatePaymentRequest request) {
        PaymentView payment = createPayment.create(PaymentWebMapper.toCommand(request));
        return ResponseEntity.created(location(payment)).body(PaymentWebMapper.toResponse(payment));
    }

    /** Implemented in T10 of spec 001; until then {@code 501}. */
    @Override
    public ResponseEntity<List<Payment>> findPayments(String externalReference) {
        throw new ErrorResponseException(HttpStatus.NOT_IMPLEMENTED);
    }

    /** Implemented in T10 of spec 001; until then {@code 501}. */
    @Override
    public ResponseEntity<Payment> getPayment(UUID id) {
        throw new ErrorResponseException(HttpStatus.NOT_IMPLEMENTED);
    }

    private static URI location(PaymentView payment) {
        return UriComponentsBuilder.fromPath(PATH_GET_PAYMENT)
                .buildAndExpand(payment.payment().id().value())
                .toUri();
    }
}
