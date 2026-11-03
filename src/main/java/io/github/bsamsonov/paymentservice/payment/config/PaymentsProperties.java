package io.github.bsamsonov.paymentservice.payment.config;

import java.util.Map;
import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Settings under {@code payments}: the provider adapter, the currency allow-list with each currency's minimum amount
 * and the maximum amount, all in minor units.
 */
@ConfigurationProperties("payments")
record PaymentsProperties(String provider, Map<String, Long> minimumAmounts, long maximumAmount) {}
