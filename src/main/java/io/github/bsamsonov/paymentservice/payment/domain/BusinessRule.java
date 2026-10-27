package io.github.bsamsonov.paymentservice.payment.domain;

/**
 * A business rule of a payment request; a violation is a {@code 422}. {@link #code()} goes to the {@code AUDIT} log.
 */
public enum BusinessRule {
    AMOUNT_BELOW_MINIMUM("amount_below_minimum"),
    AMOUNT_TOO_MANY_DIGITS("amount_too_many_digits"),
    CURRENCY_NOT_ALLOWED("currency_not_allowed");

    private final String code;

    BusinessRule(String code) {
        this.code = code;
    }

    public String code() {
        return code;
    }
}
