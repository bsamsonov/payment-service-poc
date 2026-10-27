package io.github.bsamsonov.paymentservice.payment.domain;

import java.util.Currency;

/** An amount in minor units of its currency (cents for USD); never a floating-point number. */
public record Money(long amount, Currency currency) {

    public Money {
        if (amount < 0) {
            throw new IllegalArgumentException("amount must not be negative: " + amount);
        }
    }
}
