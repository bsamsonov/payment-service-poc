package io.github.bsamsonov.paymentservice.payment.domain;

import java.util.ArrayList;
import java.util.Currency;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/** The currency allow-list with each currency's minimum amount, and the maximum amount for every currency. */
public final class CurrencyPolicy {

    private final Map<Currency, Long> minimumAmounts;
    private final long maximumAmount;

    public CurrencyPolicy(Map<Currency, Long> minimumAmounts, long maximumAmount) {
        this.minimumAmounts = Map.copyOf(minimumAmounts);
        this.maximumAmount = maximumAmount;
    }

    /** All violated rules for an amount in minor units and a currency code; empty when the request is allowed. */
    public List<RuleViolation> check(long amount, String currencyCode) {
        List<RuleViolation> violations = new ArrayList<>();
        Optional<Currency> currency = allowedCurrency(currencyCode);
        if (currency.isPresent() && amount < minimumAmounts.getOrDefault(currency.get(), 0L)) {
            violations.add(new RuleViolation("amount", BusinessRule.AMOUNT_BELOW_MINIMUM));
        }
        if (amount > maximumAmount) {
            violations.add(new RuleViolation("amount", BusinessRule.AMOUNT_TOO_MANY_DIGITS));
        }
        if (currency.isEmpty()) {
            violations.add(new RuleViolation("currency", BusinessRule.CURRENCY_NOT_ALLOWED));
        }
        return violations;
    }

    /** The currency for a code in the allow-list; empty for any other code, including codes that are not ISO 4217. */
    public Optional<Currency> allowedCurrency(String currencyCode) {
        return minimumAmounts.keySet().stream()
                .filter(currency -> currency.getCurrencyCode().equals(currencyCode))
                .findFirst();
    }
}
