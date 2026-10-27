package io.github.bsamsonov.paymentservice.payment.application.port;

/**
 * Another transaction changed the payment or its journal first (AC-14). The transaction must roll back; the change can
 * be re-applied on a fresh read.
 */
public class PaymentConcurrencyConflict extends RuntimeException {

    private static final long serialVersionUID = 1L;

    public PaymentConcurrencyConflict(String message, Throwable cause) {
        super(message, cause);
    }
}
