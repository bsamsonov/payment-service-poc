package io.github.bsamsonov.paymentservice.payment.application;

import static org.assertj.core.api.Assertions.assertThat;

import io.github.bsamsonov.paymentservice.TestcontainersConfiguration;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentProvider;
import io.github.bsamsonov.paymentservice.payment.application.port.ProviderCall;
import io.github.bsamsonov.paymentservice.payment.application.port.ProviderCharge;
import io.github.bsamsonov.paymentservice.payment.domain.Payment;
import io.github.bsamsonov.paymentservice.payment.domain.ProviderOutcome;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.support.TransactionSynchronizationManager;

@Import({TestcontainersConfiguration.class, ProviderCallTransactionIT.RecordingProviderConfig.class})
@SpringBootTest
class ProviderCallTransactionIT {

    /** What the provider saw while it was being called. */
    record SeenDuringCall(boolean transactionOpen, @Nullable String committedStatus, int committedEvents) {}

    private static final AtomicReference<@Nullable SeenDuringCall> SEEN = new AtomicReference<>();

    @Autowired
    private CreatePaymentUseCase createPayment;

    @Test
    @DisplayName("001/AC-13: the provider is called with no transaction open, after the PENDING payment is committed")
    void callsTheProviderOutsideATransactionAfterTheCommit() {
        SEEN.set(null);

        Payment payment = createPayment.create(
                new CreatePaymentCommand(1999, "USD", "pm_card_visa", "order-" + UUID.randomUUID(), null, Map.of()));

        assertThat(SEEN.get()).isEqualTo(new SeenDuringCall(false, "PENDING", 1));
        assertThat(payment.status().name()).isEqualTo("SUCCEEDED");
    }

    @TestConfiguration(proxyBeanMethods = false)
    static class RecordingProviderConfig {

        /**
         * Records whether a transaction is open and what another connection sees committed. With no transaction bound
         * to the thread, each {@link JdbcTemplate} query takes its own connection from the pool.
         */
        @Bean
        @Primary
        PaymentProvider recordingProvider(JdbcTemplate jdbc) {
            return (paymentId, amount, paymentMethodId) -> {
                boolean transactionOpen = TransactionSynchronizationManager.isActualTransactionActive();
                List<@Nullable String> status =
                        jdbc.queryForList("select status from payments where id = ?", String.class, paymentId.value());
                Integer events = jdbc.queryForObject(
                        "select count(*) from payment_events where payment_id = ?", Integer.class, paymentId.value());
                SEEN.set(new SeenDuringCall(
                        transactionOpen, status.isEmpty() ? null : status.getFirst(), events == null ? 0 : events));
                return new ProviderCharge(List.of(new ProviderCall(
                        new ProviderOutcome.Succeeded(), 200, null, "req_1", Duration.ZERO, Instant.now())));
            };
        }
    }
}
