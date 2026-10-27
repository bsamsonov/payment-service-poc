package io.github.bsamsonov.paymentservice.payment.domain;

/** A violated business rule and the request field it concerns. */
public record RuleViolation(String field, BusinessRule rule) {}
