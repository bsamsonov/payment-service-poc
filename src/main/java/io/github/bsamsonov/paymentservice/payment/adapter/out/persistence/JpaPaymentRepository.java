package io.github.bsamsonov.paymentservice.payment.adapter.out.persistence;

import io.github.bsamsonov.paymentservice.payment.application.port.PaymentConcurrencyConflict;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentForChange;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentRepository;
import io.github.bsamsonov.paymentservice.payment.domain.FailureCode;
import io.github.bsamsonov.paymentservice.payment.domain.Money;
import io.github.bsamsonov.paymentservice.payment.domain.Payment;
import io.github.bsamsonov.paymentservice.payment.domain.PaymentId;
import java.util.Currency;
import java.util.Map;
import java.util.Optional;
import org.jspecify.annotations.Nullable;
import org.springframework.dao.OptimisticLockingFailureException;
import org.springframework.stereotype.Component;

@Component
class JpaPaymentRepository implements PaymentRepository {

    private final PaymentJpaRepository payments;

    JpaPaymentRepository(PaymentJpaRepository payments) {
        this.payments = payments;
    }

    @Override
    public void add(Payment payment) {
        PaymentEntity entity = new PaymentEntity(
                payment.id().value(),
                payment.amount().amount(),
                payment.amount().currency().getCurrencyCode(),
                payment.paymentMethodId(),
                payment.externalReference(),
                payment.description(),
                payment.metadata().isEmpty() ? null : payment.metadata(),
                DomainCodes.status(payment.status()),
                payment.requestHash());
        entity.updateState(DomainCodes.status(payment.status()), failureCode(payment));
        payments.save(entity);
    }

    @Override
    public Optional<PaymentForChange> findForChange(PaymentId id) {
        return payments.findWithLastSequenceNo(id.value())
                .map(row -> new PaymentForChange(toDomain(row.payment()), row.lastSequenceNo()));
    }

    @Override
    public void update(Payment payment) {
        // The entity loaded by findForChange in this transaction: its version is the one the decision was made on
        PaymentEntity entity = payments.findById(payment.id().value())
                .orElseThrow(() -> new IllegalArgumentException("no payment " + payment.id()));
        entity.updateState(DomainCodes.status(payment.status()), failureCode(payment));
        try {
            // Flush now, so a lost update surfaces here as a conflict and not at commit
            payments.saveAndFlush(entity);
        } catch (OptimisticLockingFailureException e) {
            throw new PaymentConcurrencyConflict("payment " + payment.id() + " was changed concurrently", e);
        }
    }

    private static @Nullable String failureCode(Payment payment) {
        @Nullable FailureCode failureCode = payment.failureCode();
        return failureCode == null ? null : DomainCodes.failureCode(failureCode);
    }

    private static Payment toDomain(PaymentEntity entity) {
        @Nullable String failureCode = entity.getFailureCode();
        @Nullable Map<String, String> metadata = entity.getMetadata();
        return Payment.restore(
                new PaymentId(entity.getId()),
                new Money(entity.getAmount(), Currency.getInstance(entity.getCurrency())),
                entity.getPaymentMethodId(),
                entity.getExternalReference(),
                entity.getDescription(),
                metadata == null ? Map.of() : metadata,
                entity.getRequestHash(),
                DomainCodes.toStatus(entity.getStatus()),
                failureCode == null ? null : DomainCodes.toFailureCode(failureCode));
    }
}
