package io.github.bsamsonov.paymentservice.payment.domain;

import static io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus.FAILED;
import static io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus.PARTIALLY_REFUNDED;
import static io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus.PENDING;
import static io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus.PROCESSING;
import static io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus.REFUNDED;
import static io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus.SUCCEEDED;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.Arrays;
import java.util.Map;
import java.util.Set;
import java.util.stream.Stream;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;

class PaymentStatusTest {

    /** The forward-only state machine of spec 001; every pair not listed here is not a move. */
    private static final Map<PaymentStatus, Set<PaymentStatus>> FORWARD = Map.of(
            PENDING, Set.of(PROCESSING, SUCCEEDED, FAILED),
            PROCESSING, Set.of(SUCCEEDED, FAILED),
            SUCCEEDED, Set.of(PARTIALLY_REFUNDED, REFUNDED),
            PARTIALLY_REFUNDED, Set.of(REFUNDED),
            FAILED, Set.of(),
            REFUNDED, Set.of());

    static Stream<Arguments> everyPairOfStatuses() {
        return Arrays.stream(PaymentStatus.values())
                .flatMap(from -> Arrays.stream(PaymentStatus.values()).map(to -> Arguments.of(from, to)));
    }

    @ParameterizedTest(name = "{0} -> {1}")
    @MethodSource("everyPairOfStatuses")
    @DisplayName("001/AC-10: only forward transitions are moves; terminal states and the same status are not")
    void allowsOnlyForwardTransitions(PaymentStatus from, PaymentStatus to) {
        assertThat(from.canMoveTo(to))
                .isEqualTo(FORWARD.getOrDefault(from, Set.of()).contains(to));
    }
}
