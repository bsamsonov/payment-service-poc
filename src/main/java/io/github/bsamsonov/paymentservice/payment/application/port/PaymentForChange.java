package io.github.bsamsonov.paymentservice.payment.application.port;

import io.github.bsamsonov.paymentservice.payment.domain.Payment;

/** A payment and the sequence number of its last journal event (0 if none), read together. */
public record PaymentForChange(Payment payment, long lastSequenceNo) {}
