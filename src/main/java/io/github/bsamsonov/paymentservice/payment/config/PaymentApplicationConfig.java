package io.github.bsamsonov.paymentservice.payment.config;

import io.github.bsamsonov.paymentservice.payment.application.PaymentStatusApplier;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentJournal;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentRepository;
import io.github.bsamsonov.paymentservice.payment.application.port.TraceContext;
import java.time.Clock;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.transaction.support.TransactionTemplate;

/** Wires the use cases of the payment module; the application layer has no Spring stereotypes. */
@Configuration(proxyBeanMethods = false)
class PaymentApplicationConfig {

    @Bean
    PaymentStatusApplier paymentStatusApplier(
            PaymentRepository payments,
            PaymentJournal journal,
            TraceContext traceContext,
            TransactionTemplate transaction,
            Clock clock) {
        return new PaymentStatusApplier(payments, journal, traceContext, transaction, clock);
    }
}
