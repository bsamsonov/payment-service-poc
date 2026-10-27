package io.github.bsamsonov.paymentservice.payment.domain;

/** Status of a payment; it changes only forward, through {@link #canMoveTo}. */
public enum PaymentStatus {
    PENDING,
    PROCESSING,
    SUCCEEDED,
    FAILED,
    PARTIALLY_REFUNDED,
    REFUNDED;

    /** Whether a payment in this status may move to {@code target}; the same status is never a move. */
    public boolean canMoveTo(PaymentStatus target) {
        return switch (this) {
            case PENDING -> target == PROCESSING || target == SUCCEEDED || target == FAILED;
            case PROCESSING -> target == SUCCEEDED || target == FAILED;
            case SUCCEEDED -> target == PARTIALLY_REFUNDED || target == REFUNDED;
            case PARTIALLY_REFUNDED -> target == REFUNDED;
            case FAILED, REFUNDED -> false;
        };
    }
}
