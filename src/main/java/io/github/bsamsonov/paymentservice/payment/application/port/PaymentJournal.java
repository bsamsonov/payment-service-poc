package io.github.bsamsonov.paymentservice.payment.application.port;

import io.github.bsamsonov.paymentservice.payment.domain.PaymentEvent;
import io.github.bsamsonov.paymentservice.payment.domain.ProviderAttempt;

/** The append-only logs of a payment: the audit log of events and the log of provider calls. */
public interface PaymentJournal {

    /**
     * Appends an event to the audit log.
     *
     * @throws PaymentConcurrencyConflict if another transaction took the event's sequence number
     */
    void append(PaymentEvent event);

    /** Appends a provider call to its log. */
    void append(ProviderAttempt attempt);
}
