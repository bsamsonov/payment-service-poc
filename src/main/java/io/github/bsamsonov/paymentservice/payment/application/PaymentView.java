package io.github.bsamsonov.paymentservice.payment.application;

import io.github.bsamsonov.paymentservice.payment.domain.Payment;
import java.time.Instant;

/** What the use cases return about a payment: the payment and the timestamps the store keeps for it. */
public record PaymentView(Payment payment, Instant createdAt, Instant updatedAt) {}
