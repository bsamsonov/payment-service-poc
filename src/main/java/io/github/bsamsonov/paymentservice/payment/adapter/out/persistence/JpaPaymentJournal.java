package io.github.bsamsonov.paymentservice.payment.adapter.out.persistence;

import io.github.bsamsonov.paymentservice.payment.application.port.PaymentConcurrencyConflict;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentJournal;
import io.github.bsamsonov.paymentservice.payment.domain.FailureCode;
import io.github.bsamsonov.paymentservice.payment.domain.PaymentEvent;
import io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus;
import io.github.bsamsonov.paymentservice.payment.domain.ProviderAttempt;
import io.github.bsamsonov.paymentservice.payment.domain.RejectionReason;
import java.time.Clock;
import java.time.Instant;
import org.hibernate.exception.ConstraintViolationException;
import org.jspecify.annotations.Nullable;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Component;

@Component
class JpaPaymentJournal implements PaymentJournal {

    private static final String SEQUENCE_UNIQUE = "payment_events_sequence_unique";

    private final PaymentEventJpaRepository events;
    private final ProviderAttemptJpaRepository attempts;
    private final Clock clock;

    JpaPaymentJournal(PaymentEventJpaRepository events, ProviderAttemptJpaRepository attempts, Clock clock) {
        this.events = events;
        this.attempts = attempts;
        this.clock = clock;
    }

    @Override
    public void append(PaymentEvent event) {
        @Nullable PaymentStatus fromStatus = event.fromStatus();
        @Nullable FailureCode failureCode = event.failureCode();
        @Nullable RejectionReason reason = event.reason();
        PaymentEventEntity entity = new PaymentEventEntity(
                event.id(),
                event.paymentId().value(),
                event.sequenceNo(),
                DomainCodes.eventType(event.type()),
                fromStatus == null ? null : DomainCodes.status(fromStatus),
                DomainCodes.status(event.toStatus()),
                failureCode == null ? null : DomainCodes.failureCode(failureCode),
                reason == null ? null : reason.code(),
                event.origin().actorType().name(),
                event.origin().source().name(),
                event.traceId(),
                event.occurredAt(),
                Instant.now(clock));
        try {
            // Flush now, so a sequence collision surfaces here as a conflict and not at commit
            events.saveAndFlush(entity);
        } catch (DataIntegrityViolationException e) {
            if (violates(e, SEQUENCE_UNIQUE)) {
                throw new PaymentConcurrencyConflict(
                        "sequence_no " + event.sequenceNo() + " of payment " + event.paymentId() + " is taken", e);
            }
            throw e;
        }
    }

    @Override
    public void append(ProviderAttempt attempt) {
        @Nullable Integer httpStatus = attempt.providerHttpStatus();
        attempts.save(new ProviderAttemptEntity(
                attempt.id(),
                attempt.paymentId().value(),
                attempt.attemptNo(),
                DomainCodes.outcome(attempt.outcome()),
                httpStatus == null ? null : httpStatus.shortValue(),
                attempt.providerCode(),
                attempt.providerRequestId(),
                Math.toIntExact(attempt.duration().toMillis()),
                attempt.traceId(),
                attempt.startedAt(),
                Instant.now(clock)));
    }

    private static boolean violates(DataIntegrityViolationException e, String constraint) {
        for (Throwable cause = e; cause != null; cause = cause.getCause()) {
            if (cause instanceof ConstraintViolationException violation
                    && constraint.equals(violation.getConstraintName())) {
                return true;
            }
        }
        return false;
    }
}
