package io.github.bsamsonov.paymentservice.payment.domain;

/** The channel an event came through; the channel, not the operation (a refund is an event type, not a source). */
public enum EventSource {
    API,
    PROVIDER_RESPONSE
}
