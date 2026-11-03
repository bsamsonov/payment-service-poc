package io.github.bsamsonov.paymentservice.payment.application;

import com.github.f4b6a3.uuid.UuidCreator;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentJournal;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentProvider;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentRepository;
import io.github.bsamsonov.paymentservice.payment.application.port.ProviderCall;
import io.github.bsamsonov.paymentservice.payment.application.port.ProviderCharge;
import io.github.bsamsonov.paymentservice.payment.application.port.TraceContext;
import io.github.bsamsonov.paymentservice.payment.domain.CurrencyPolicy;
import io.github.bsamsonov.paymentservice.payment.domain.EventOrigin;
import io.github.bsamsonov.paymentservice.payment.domain.EventType;
import io.github.bsamsonov.paymentservice.payment.domain.FailureCode;
import io.github.bsamsonov.paymentservice.payment.domain.Money;
import io.github.bsamsonov.paymentservice.payment.domain.Payment;
import io.github.bsamsonov.paymentservice.payment.domain.PaymentEvent;
import io.github.bsamsonov.paymentservice.payment.domain.PaymentId;
import io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus;
import io.github.bsamsonov.paymentservice.payment.domain.ProviderAttempt;
import io.github.bsamsonov.paymentservice.payment.domain.ProviderOutcome.Declined;
import io.github.bsamsonov.paymentservice.payment.domain.ProviderOutcome.Rejected;
import io.github.bsamsonov.paymentservice.payment.domain.ProviderOutcome.Succeeded;
import io.github.bsamsonov.paymentservice.payment.domain.ProviderOutcome.Unknown;
import io.github.bsamsonov.paymentservice.payment.domain.RuleViolation;
import java.time.Clock;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Currency;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.jspecify.annotations.Nullable;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Creates a payment and charges it (spec 001, Flow): Tx 1 stores the {@code PENDING} payment with
 * {@code PAYMENT_CREATED}; the provider is called with no transaction open (AC-13); the status applier then records the
 * provider attempts and the resulting status in one transaction (AC-15).
 */
public final class CreatePaymentUseCase {

    private static final Logger log = LoggerFactory.getLogger(CreatePaymentUseCase.class);

    private final CurrencyPolicy currencyPolicy;
    private final PaymentRepository payments;
    private final PaymentJournal journal;
    private final PaymentProvider provider;
    private final PaymentStatusApplier statusApplier;
    private final TraceContext traceContext;
    private final TransactionTemplate transaction;
    private final Clock clock;

    @SuppressWarnings({"TooManyParameters", "PMD.ExcessiveParameterList"}) // one parameter per collaborator
    public CreatePaymentUseCase(
            CurrencyPolicy currencyPolicy,
            PaymentRepository payments,
            PaymentJournal journal,
            PaymentProvider provider,
            PaymentStatusApplier statusApplier,
            TraceContext traceContext,
            TransactionTemplate transaction,
            Clock clock) {
        this.currencyPolicy = currencyPolicy;
        this.payments = payments;
        this.journal = journal;
        this.provider = provider;
        this.statusApplier = statusApplier;
        this.traceContext = traceContext;
        this.transaction = transaction;
        this.clock = clock;
    }

    /**
     * Creates and charges a payment and returns it in its resulting status.
     *
     * @throws BusinessRuleViolation if the request breaks a business rule; no payment is created
     * @throws IllegalStateException if called inside a transaction: the provider would be called with it open
     */
    public Payment create(CreatePaymentCommand command) {
        if (TransactionSynchronizationManager.isActualTransactionActive()) {
            throw new IllegalStateException("a payment must be created outside a transaction");
        }
        List<RuleViolation> violations = currencyPolicy.check(command.amount(), command.currency());
        if (!violations.isEmpty()) {
            throw new BusinessRuleViolation(violations);
        }
        Currency currency = currencyPolicy.allowedCurrency(command.currency()).orElseThrow();
        Money amount = new Money(command.amount(), currency);
        PaymentId id = new PaymentId(UuidCreator.getTimeOrderedEpoch());
        Payment payment = Payment.create(
                id,
                amount,
                command.paymentMethodId(),
                command.externalReference(),
                command.description(),
                command.metadata(),
                RequestHasher.hash(requestFields(command)));

        transaction.executeWithoutResult(tx -> {
            payments.add(payment);
            journal.append(new PaymentEvent(
                    UuidCreator.getTimeOrderedEpoch(),
                    id,
                    1,
                    EventType.PAYMENT_CREATED,
                    null,
                    PaymentStatus.PENDING,
                    null,
                    null,
                    EventOrigin.CLIENT_API,
                    traceContext.currentTraceId(),
                    Instant.now(clock)));
        });
        log.info("Payment {} created", id);

        ProviderCharge charge = provider.charge(id, amount, command.paymentMethodId());
        List<ProviderAttempt> attempts = attempts(id, charge);
        try {
            switch (charge.outcome()) {
                case Succeeded _ -> apply(id, PaymentStatus.SUCCEEDED, null, attempts);
                case Declined declined -> apply(id, PaymentStatus.FAILED, declined.code(), attempts);
                case Rejected _ -> apply(id, PaymentStatus.FAILED, FailureCode.PROVIDER_ERROR, attempts);
                case Unknown _ -> apply(id, PaymentStatus.PROCESSING, null, attempts);
            }
        } catch (RuntimeException e) {
            // Tx 2 rolled back: the charge result exists only here, so it is logged before the failure propagates.
            // No stack trace: whoever handles the rethrown exception logs it (RC-14)
            log.error(
                    "Payment {}: provider outcome {} not recorded, provider request ids {}",
                    id,
                    charge.outcome(),
                    attempts.stream().map(ProviderAttempt::providerRequestId).toList());
            throw e;
        }
        return payments.findById(id).orElseThrow(() -> new IllegalStateException("payment " + id + " vanished"));
    }

    private void apply(
            PaymentId id, PaymentStatus target, @Nullable FailureCode failureCode, List<ProviderAttempt> attempts) {
        statusApplier.apply(id, target, failureCode, EventOrigin.PROVIDER_RESPONSE, attempts);
    }

    private List<ProviderAttempt> attempts(PaymentId id, ProviderCharge charge) {
        List<ProviderAttempt> attempts = new ArrayList<>();
        @Nullable String traceId = traceContext.currentTraceId();
        for (ProviderCall call : charge.calls()) {
            attempts.add(new ProviderAttempt(
                    UuidCreator.getTimeOrderedEpoch(),
                    id,
                    attempts.size() + 1,
                    call.outcome(),
                    call.httpStatus(),
                    call.providerCode(),
                    call.providerRequestId(),
                    call.duration(),
                    traceId,
                    call.startedAt()));
        }
        return attempts;
    }

    /** All request fields under their API names; absent ones are null and left out of the hash (AC-17). */
    private static Map<String, @Nullable Object> requestFields(CreatePaymentCommand command) {
        Map<String, @Nullable Object> fields = new HashMap<>();
        fields.put("amount", command.amount());
        fields.put("currency", command.currency());
        fields.put("paymentMethodId", command.paymentMethodId());
        fields.put("externalReference", command.externalReference());
        fields.put("description", command.description());
        fields.put("metadata", command.metadata());
        return fields;
    }
}
