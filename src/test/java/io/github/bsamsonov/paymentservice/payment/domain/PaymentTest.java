package io.github.bsamsonov.paymentservice.payment.domain;

import static io.github.bsamsonov.paymentservice.payment.domain.FailureCode.CARD_DECLINED;
import static io.github.bsamsonov.paymentservice.payment.domain.FailureCode.INSUFFICIENT_FUNDS;
import static io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus.FAILED;
import static io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus.PENDING;
import static io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus.PROCESSING;
import static io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus.SUCCEEDED;
import static io.github.bsamsonov.paymentservice.payment.domain.RejectionReason.CONFLICTING_DUPLICATE;
import static io.github.bsamsonov.paymentservice.payment.domain.RejectionReason.TRANSITION_NOT_ALLOWED;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.github.bsamsonov.paymentservice.payment.domain.TransitionResult.Applied;
import io.github.bsamsonov.paymentservice.payment.domain.TransitionResult.NoOp;
import io.github.bsamsonov.paymentservice.payment.domain.TransitionResult.Rejected;
import java.util.Currency;
import java.util.Map;
import java.util.UUID;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

class PaymentTest {

    private static final Money AMOUNT = new Money(1999, Currency.getInstance("USD"));

    @Test
    @DisplayName("a new payment starts in PENDING without a failure code")
    void startsPending() {
        Payment payment = newPayment();

        assertThat(payment.status()).isEqualTo(PENDING);
        assertThat(payment.failureCode()).isNull();
    }

    @Test
    @DisplayName("001/AC-10: a forward transition is applied and changes the status")
    void appliesForwardTransition() {
        Payment payment = newPayment();

        TransitionResult result = payment.apply(SUCCEEDED, null);

        assertThat(result).isEqualTo(new Applied(PENDING, SUCCEEDED, null));
        assertThat(payment.status()).isEqualTo(SUCCEEDED);
    }

    @Test
    @DisplayName("001/AC-10: a transition to FAILED stores the failure code")
    void appliesFailureWithCode() {
        Payment payment = newPayment();

        TransitionResult result = payment.apply(FAILED, CARD_DECLINED);

        assertThat(result).isEqualTo(new Applied(PENDING, FAILED, CARD_DECLINED));
        assertThat(payment.status()).isEqualTo(FAILED);
        assertThat(payment.failureCode()).isEqualTo(CARD_DECLINED);
    }

    @Test
    @DisplayName("001/AC-10: a backward transition is rejected and the payment is unchanged")
    void rejectsBackwardTransition() {
        Payment payment = paymentIn(PROCESSING, null);

        TransitionResult result = payment.apply(PENDING, null);

        assertThat(result).isEqualTo(new Rejected(PROCESSING, PENDING, null, TRANSITION_NOT_ALLOWED));
        assertThat(payment.status()).isEqualTo(PROCESSING);
    }

    @Test
    @DisplayName("001/AC-10: a transition out of a terminal state is rejected and the payment is unchanged")
    void rejectsTransitionOutOfTerminalState() {
        Payment payment = paymentIn(FAILED, CARD_DECLINED);

        TransitionResult result = payment.apply(SUCCEEDED, null);

        assertThat(result).isEqualTo(new Rejected(FAILED, SUCCEEDED, null, TRANSITION_NOT_ALLOWED));
        assertThat(payment.status()).isEqualTo(FAILED);
        assertThat(payment.failureCode()).isEqualTo(CARD_DECLINED);
    }

    @Test
    @DisplayName("001/AC-10: the current status with identical data again is a no-op")
    void identicalDuplicateIsNoOp() {
        Payment succeeded = paymentIn(SUCCEEDED, null);
        Payment failed = paymentIn(FAILED, CARD_DECLINED);

        assertThat(succeeded.apply(SUCCEEDED, null)).isEqualTo(new NoOp());
        assertThat(failed.apply(FAILED, CARD_DECLINED)).isEqualTo(new NoOp());
    }

    @Test
    @DisplayName("001/AC-10: the current status with another failure code is a conflicting duplicate; the code stays")
    void conflictingDuplicateIsRejected() {
        Payment payment = paymentIn(FAILED, CARD_DECLINED);

        TransitionResult result = payment.apply(FAILED, INSUFFICIENT_FUNDS);

        assertThat(result).isEqualTo(new Rejected(FAILED, FAILED, INSUFFICIENT_FUNDS, CONFLICTING_DUPLICATE));
        assertThat(payment.failureCode()).isEqualTo(CARD_DECLINED);
    }

    @Test
    @DisplayName("a failure code is required for FAILED and not allowed for any other status")
    void failureCodeBelongsOnlyToFailed() {
        Payment payment = newPayment();

        assertThatThrownBy(() -> payment.apply(FAILED, null)).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> payment.apply(SUCCEEDED, CARD_DECLINED)).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> paymentIn(SUCCEEDED, CARD_DECLINED)).isInstanceOf(IllegalArgumentException.class);
        assertThat(payment.status()).isEqualTo(PENDING);
    }

    private static Payment newPayment() {
        return Payment.create(
                new PaymentId(UUID.randomUUID()), AMOUNT, "pm_card_visa", "order-1", null, Map.of(), "a".repeat(64));
    }

    private static Payment paymentIn(PaymentStatus status, @Nullable FailureCode failureCode) {
        return Payment.restore(
                new PaymentId(UUID.randomUUID()),
                AMOUNT,
                "pm_card_visa",
                "order-1",
                null,
                Map.of(),
                "a".repeat(64),
                status,
                failureCode);
    }
}
