package io.github.bsamsonov.paymentservice.payment.domain;

/** Why a payment failed; {@link #code()} is the value in the API and in the database. */
public enum FailureCode {
    CARD_DECLINED("card_declined"),
    INSUFFICIENT_FUNDS("insufficient_funds"),
    AUTHENTICATION_REQUIRED("authentication_required"),
    INVALID_PAYMENT_METHOD("invalid_payment_method"),
    /** The provider refused our request; no money moved. */
    PROVIDER_ERROR("provider_error");

    private final String code;

    FailureCode(String code) {
        this.code = code;
    }

    public String code() {
        return code;
    }
}
