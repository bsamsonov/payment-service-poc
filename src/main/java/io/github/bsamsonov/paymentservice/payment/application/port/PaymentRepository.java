package io.github.bsamsonov.paymentservice.payment.application.port;

import io.github.bsamsonov.paymentservice.payment.domain.Payment;
import io.github.bsamsonov.paymentservice.payment.domain.PaymentId;
import java.util.Optional;

/** Stored payments; they are never deleted. */
public interface PaymentRepository {

    /** Stores a new payment. */
    void add(Payment payment);

    /**
     * Loads a payment to change its status, together with the last journal sequence number, in one read (one snapshot).
     * The change must be saved with {@link #update} in the same transaction.
     */
    Optional<PaymentForChange> findForChange(PaymentId id);

    /**
     * Saves the status of a payment loaded with {@link #findForChange} in this transaction.
     *
     * @throws PaymentConcurrencyConflict if another transaction changed the payment since it was loaded
     */
    void update(Payment payment);
}
