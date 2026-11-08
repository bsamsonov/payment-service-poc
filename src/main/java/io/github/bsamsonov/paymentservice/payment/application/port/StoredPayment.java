package io.github.bsamsonov.paymentservice.payment.application.port;

import io.github.bsamsonov.paymentservice.payment.domain.Payment;
import java.time.Instant;

/** A payment as stored, with the timestamps the store keeps for it (they are not part of the domain). */
public record StoredPayment(Payment payment, Instant createdAt, Instant updatedAt) {}
