package io.github.bsamsonov.paymentservice.payment.domain;

/** Why a transition was rejected; {@link #code()} is stored as the event's {@code reason_code}. */
public enum RejectionReason {
    /** Backward, or out of a terminal state. */
    TRANSITION_NOT_ALLOWED("transition_not_allowed"),
    /** The current status again, with different data (e.g. another failure code). */
    CONFLICTING_DUPLICATE("conflicting_duplicate");

    private final String code;

    RejectionReason(String code) {
        this.code = code;
    }

    public String code() {
        return code;
    }
}
