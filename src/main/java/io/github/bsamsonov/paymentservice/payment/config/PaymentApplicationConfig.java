package io.github.bsamsonov.paymentservice.payment.config;

import io.github.bsamsonov.paymentservice.payment.application.CreatePaymentUseCase;
import io.github.bsamsonov.paymentservice.payment.application.PaymentStatusApplier;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentJournal;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentProvider;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentRepository;
import io.github.bsamsonov.paymentservice.payment.application.port.TraceContext;
import io.github.bsamsonov.paymentservice.payment.domain.CurrencyPolicy;
import java.time.Clock;
import java.util.Currency;
import java.util.Map;
import java.util.stream.Collectors;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.transaction.support.TransactionTemplate;

/** Wires the use cases of the payment module; the application layer has no Spring stereotypes. */
@Configuration(proxyBeanMethods = false)
@EnableConfigurationProperties(PaymentsProperties.class)
class PaymentApplicationConfig {

    @Bean
    CurrencyPolicy currencyPolicy(PaymentsProperties properties) {
        Map<Currency, Long> minimumAmounts = properties.minimumAmounts().entrySet().stream()
                .collect(Collectors.toMap(entry -> Currency.getInstance(entry.getKey()), Map.Entry::getValue));
        return new CurrencyPolicy(minimumAmounts, properties.maximumAmount());
    }

    @Bean
    PaymentStatusApplier paymentStatusApplier(
            PaymentRepository payments,
            PaymentJournal journal,
            TraceContext traceContext,
            TransactionTemplate transaction,
            Clock clock) {
        return new PaymentStatusApplier(payments, journal, traceContext, transaction, clock);
    }

    @Bean
    @SuppressWarnings({"TooManyParameters", "PMD.ExcessiveParameterList"}) // one parameter per collaborator
    CreatePaymentUseCase createPaymentUseCase(
            CurrencyPolicy currencyPolicy,
            PaymentRepository payments,
            PaymentJournal journal,
            PaymentProvider provider,
            PaymentStatusApplier statusApplier,
            TraceContext traceContext,
            TransactionTemplate transaction,
            Clock clock) {
        return new CreatePaymentUseCase(
                currencyPolicy, payments, journal, provider, statusApplier, traceContext, transaction, clock);
    }
}
