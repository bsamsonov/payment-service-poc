package io.github.bsamsonov.paymentservice.payment.domain;

import org.jspecify.annotations.Nullable;

/** Outcome of {@link Payment#apply}: what the status applier journals. */
public sealed interface TransitionResult {

    /** The status changed; journaled as {@code STATUS_CHANGED}. */
    record Applied(
            PaymentStatus from, PaymentStatus to, @Nullable FailureCode failureCode) implements TransitionResult {}

    /** The current status again with identical data; nothing is journaled. */
    record NoOp() implements TransitionResult {}

    /**
     * The payment did not change; journaled as {@code TRANSITION_REJECTED} with the requested status and failure code.
     */
    record Rejected(
            PaymentStatus from,
            PaymentStatus requested,
            @Nullable FailureCode requestedFailureCode,
            RejectionReason reason)
            implements TransitionResult {}
}
