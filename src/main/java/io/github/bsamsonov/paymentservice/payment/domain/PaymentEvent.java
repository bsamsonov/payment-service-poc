package io.github.bsamsonov.paymentservice.payment.domain;

import java.time.Instant;
import java.util.UUID;
import org.jspecify.annotations.Nullable;

/**
 * An entry of the payment audit log: the change only, never the payment's data. {@code failureCode} is the new code on
 * {@code STATUS_CHANGED} to {@code FAILED} and the requested code on {@code TRANSITION_REJECTED}.
 */
@SuppressWarnings({"TooManyParameters", "PMD.ExcessiveParameterList"}) // one component per journal column
public record PaymentEvent(
        UUID id,
        PaymentId paymentId,
        long sequenceNo,
        EventType type,
        @Nullable PaymentStatus fromStatus,
        PaymentStatus toStatus,
        @Nullable FailureCode failureCode,
        @Nullable RejectionReason reason,
        EventOrigin origin,
        @Nullable String traceId,
        Instant occurredAt) {}
