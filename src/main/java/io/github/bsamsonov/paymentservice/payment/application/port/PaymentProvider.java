package io.github.bsamsonov.paymentservice.payment.application.port;

import io.github.bsamsonov.paymentservice.payment.domain.Money;
import io.github.bsamsonov.paymentservice.payment.domain.PaymentId;

/** The payment provider. Called outside any database transaction (AC-13). */
public interface PaymentProvider {

    /**
     * Charges a payment. A refusal, an error or a timeout of the provider is an outcome, not an exception; the charge
     * lists every call made, so each one can be recorded (AC-15).
     */
    ProviderCharge charge(PaymentId paymentId, Money amount, String paymentMethodId);
}
