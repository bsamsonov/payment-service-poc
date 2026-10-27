package io.github.bsamsonov.paymentservice.payment.domain;

import java.util.Map;
import java.util.Objects;
import org.jspecify.annotations.Nullable;

/** The payment aggregate. Its status changes only through {@link #apply}. */
public final class Payment {

    private final PaymentId id;
    private final Money amount;
    private final String paymentMethodId;
    private final String externalReference;
    private final @Nullable String description;
    private final Map<String, String> metadata;
    private final String requestHash;
    private PaymentStatus status;
    private @Nullable FailureCode failureCode;

    @SuppressWarnings({"TooManyParameters", "PMD.ExcessiveParameterList"}) // one parameter per payment field
    private Payment(
            PaymentId id,
            Money amount,
            String paymentMethodId,
            String externalReference,
            @Nullable String description,
            Map<String, String> metadata,
            String requestHash,
            PaymentStatus status,
            @Nullable FailureCode failureCode) {
        requireFailureCodeOnlyWhenFailed(status, failureCode);
        this.id = id;
        this.amount = amount;
        this.paymentMethodId = paymentMethodId;
        this.externalReference = externalReference;
        this.description = description;
        this.metadata = Map.copyOf(metadata);
        this.requestHash = requestHash;
        this.status = status;
        this.failureCode = failureCode;
    }

    /** A new payment in {@code PENDING}; the request has already passed the business rules. */
    public static Payment create(
            PaymentId id,
            Money amount,
            String paymentMethodId,
            String externalReference,
            @Nullable String description,
            Map<String, String> metadata,
            String requestHash) {
        return new Payment(
                id,
                amount,
                paymentMethodId,
                externalReference,
                description,
                metadata,
                requestHash,
                PaymentStatus.PENDING,
                null);
    }

    /** A stored payment, as it was loaded. */
    @SuppressWarnings({"TooManyParameters", "PMD.ExcessiveParameterList"}) // one parameter per payment field
    public static Payment restore(
            PaymentId id,
            Money amount,
            String paymentMethodId,
            String externalReference,
            @Nullable String description,
            Map<String, String> metadata,
            String requestHash,
            PaymentStatus status,
            @Nullable FailureCode failureCode) {
        return new Payment(
                id,
                amount,
                paymentMethodId,
                externalReference,
                description,
                metadata,
                requestHash,
                status,
                failureCode);
    }

    /**
     * Applies a requested status. A forward move changes the payment; anything else leaves it unchanged and is either a
     * no-op (the current status with identical data) or a rejection to be journaled. {@code failureCode} is required
     * for {@code FAILED} and not allowed otherwise.
     */
    public TransitionResult apply(PaymentStatus target, @Nullable FailureCode requestedFailureCode) {
        requireFailureCodeOnlyWhenFailed(target, requestedFailureCode);
        if (target == status) {
            return Objects.equals(requestedFailureCode, failureCode)
                    ? new TransitionResult.NoOp()
                    : new TransitionResult.Rejected(
                            status, target, requestedFailureCode, RejectionReason.CONFLICTING_DUPLICATE);
        }
        if (!status.canMoveTo(target)) {
            return new TransitionResult.Rejected(
                    status, target, requestedFailureCode, RejectionReason.TRANSITION_NOT_ALLOWED);
        }
        PaymentStatus from = status;
        status = target;
        failureCode = requestedFailureCode;
        return new TransitionResult.Applied(from, target, requestedFailureCode);
    }

    private static void requireFailureCodeOnlyWhenFailed(PaymentStatus status, @Nullable FailureCode failureCode) {
        if ((status == PaymentStatus.FAILED) != (failureCode != null)) {
            throw new IllegalArgumentException(
                    "a failure code goes with FAILED only: status " + status + ", failure code " + failureCode);
        }
    }

    public PaymentId id() {
        return id;
    }

    public Money amount() {
        return amount;
    }

    public String paymentMethodId() {
        return paymentMethodId;
    }

    public String externalReference() {
        return externalReference;
    }

    public @Nullable String description() {
        return description;
    }

    public Map<String, String> metadata() {
        return metadata;
    }

    public String requestHash() {
        return requestHash;
    }

    public PaymentStatus status() {
        return status;
    }

    public @Nullable FailureCode failureCode() {
        return failureCode;
    }
}
