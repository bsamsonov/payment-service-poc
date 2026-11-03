package io.github.bsamsonov.paymentservice.payment.application;

import io.github.bsamsonov.paymentservice.payment.domain.RuleViolation;
import java.util.List;

/** A request that breaks business rules ({@code 422}); it lists every violated rule and creates no payment. */
public class BusinessRuleViolation extends RuntimeException {

    private static final long serialVersionUID = 1L;

    @SuppressWarnings("serial") // an immutable list of records; the exception is never serialized
    private final List<RuleViolation> violations;

    public BusinessRuleViolation(List<RuleViolation> violations) {
        super("business rules violated: "
                + violations.stream().map(v -> v.rule().code()).toList());
        this.violations = List.copyOf(violations);
    }

    public List<RuleViolation> violations() {
        return violations;
    }
}
