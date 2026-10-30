package io.github.bsamsonov.paymentservice.payment.adapter.out.persistence;

import io.github.bsamsonov.paymentservice.payment.domain.EventType;
import io.github.bsamsonov.paymentservice.payment.domain.FailureCode;
import io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus;
import io.github.bsamsonov.paymentservice.payment.domain.ProviderOutcome;
import java.util.Arrays;

/** The stored codes of the domain enums; {@code CodedValueDomainsIT} checks them against the database domains. */
final class DomainCodes {

    private DomainCodes() {}

    static String status(PaymentStatus status) {
        return status.name();
    }

    static PaymentStatus toStatus(String code) {
        return PaymentStatus.valueOf(code);
    }

    static String failureCode(FailureCode failureCode) {
        return failureCode.code();
    }

    static FailureCode toFailureCode(String code) {
        return Arrays.stream(FailureCode.values())
                .filter(failureCode -> failureCode.code().equals(code))
                .findFirst()
                .orElseThrow(() -> new IllegalArgumentException("unknown failure code: " + code));
    }

    static String eventType(EventType type) {
        return type.name();
    }

    static String outcome(ProviderOutcome outcome) {
        return switch (outcome) {
            case ProviderOutcome.Succeeded _ -> "SUCCEEDED";
            case ProviderOutcome.Declined _ -> "DECLINED";
            case ProviderOutcome.Rejected _ -> "REJECTED";
            case ProviderOutcome.Unknown _ -> "UNKNOWN";
        };
    }
}
