package io.github.bsamsonov.paymentservice.payment.domain;

import static io.github.bsamsonov.paymentservice.payment.domain.BusinessRule.AMOUNT_BELOW_MINIMUM;
import static io.github.bsamsonov.paymentservice.payment.domain.BusinessRule.AMOUNT_TOO_MANY_DIGITS;
import static io.github.bsamsonov.paymentservice.payment.domain.BusinessRule.CURRENCY_NOT_ALLOWED;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.Currency;
import java.util.Map;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

class CurrencyPolicyTest {

    // v1: USD only, minimum 50 cents, at most 8 digits
    private final CurrencyPolicy policy = new CurrencyPolicy(Map.of(Currency.getInstance("USD"), 50L), 99_999_999L);

    @ParameterizedTest(name = "{0}")
    @ValueSource(longs = {50, 1999, 99_999_999})
    @DisplayName("001/AC-6: an allowed currency with an amount within its bounds has no violations")
    void acceptsAmountWithinBounds(long amount) {
        assertThat(policy.check(amount, "USD")).isEmpty();
    }

    @ParameterizedTest(name = "{0}")
    @ValueSource(longs = {49, 1, 0, -1})
    @DisplayName("001/AC-6: an amount below the currency minimum is a violation")
    void rejectsAmountBelowMinimum(long amount) {
        assertThat(policy.check(amount, "USD")).containsExactly(new RuleViolation("amount", AMOUNT_BELOW_MINIMUM));
    }

    @Test
    @DisplayName("001/AC-6: an amount with more than 8 digits is a violation")
    void rejectsAmountWithTooManyDigits() {
        assertThat(policy.check(100_000_000, "USD"))
                .containsExactly(new RuleViolation("amount", AMOUNT_TOO_MANY_DIGITS));
    }

    @ParameterizedTest(name = "{0}")
    @ValueSource(strings = {"EUR", "XYZ"})
    @DisplayName("001/AC-6: a currency outside the allow-list is a violation, also when it is not an ISO code")
    void rejectsCurrencyOutsideAllowList(String currency) {
        assertThat(policy.check(1999, currency)).containsExactly(new RuleViolation("currency", CURRENCY_NOT_ALLOWED));
    }

    @Test
    @DisplayName("001/AC-6: all violations are reported together")
    void reportsAllViolations() {
        assertThat(policy.check(100_000_000, "EUR"))
                .containsExactly(
                        new RuleViolation("amount", AMOUNT_TOO_MANY_DIGITS),
                        new RuleViolation("currency", CURRENCY_NOT_ALLOWED));
    }

    @Test
    @DisplayName("an allowed currency code becomes a Currency")
    void resolvesAllowedCurrency() {
        assertThat(policy.allowedCurrency("USD")).contains(Currency.getInstance("USD"));
        assertThat(policy.allowedCurrency("EUR")).isEmpty();
    }
}
