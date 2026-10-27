package io.github.bsamsonov.paymentservice.payment.domain;

/** What happened to a payment; one {@code payment_events} row each. */
public enum EventType {
    PAYMENT_CREATED,
    STATUS_CHANGED,
    TRANSITION_REJECTED
}
