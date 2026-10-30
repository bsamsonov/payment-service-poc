package io.github.bsamsonov.paymentservice.payment.application;

import com.github.f4b6a3.uuid.UuidCreator;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentConcurrencyConflict;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentForChange;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentJournal;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentRepository;
import io.github.bsamsonov.paymentservice.payment.application.port.TraceContext;
import io.github.bsamsonov.paymentservice.payment.domain.EventOrigin;
import io.github.bsamsonov.paymentservice.payment.domain.EventType;
import io.github.bsamsonov.paymentservice.payment.domain.FailureCode;
import io.github.bsamsonov.paymentservice.payment.domain.Payment;
import io.github.bsamsonov.paymentservice.payment.domain.PaymentEvent;
import io.github.bsamsonov.paymentservice.payment.domain.PaymentId;
import io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus;
import io.github.bsamsonov.paymentservice.payment.domain.RejectionReason;
import io.github.bsamsonov.paymentservice.payment.domain.TransitionResult;
import io.github.bsamsonov.paymentservice.payment.domain.TransitionResult.Applied;
import io.github.bsamsonov.paymentservice.payment.domain.TransitionResult.NoOp;
import io.github.bsamsonov.paymentservice.payment.domain.TransitionResult.Rejected;
import java.time.Clock;
import java.time.Instant;
import java.util.Objects;
import org.jspecify.annotations.Nullable;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * The only way a payment's status changes (AC-10, AC-11, AC-14). Each attempt runs in its own transaction: read the
 * payment with its last sequence number, decide, save the payment if the status changed, append the event, commit. A
 * concurrent change makes the attempt roll back; it is re-applied on a fresh read, at most {@value #MAX_ATTEMPTS}
 * times. Call it outside a transaction, so that each attempt can roll back on its own.
 */
public final class PaymentStatusApplier {

    static final int MAX_ATTEMPTS = 3;

    private static final Logger log = LoggerFactory.getLogger(PaymentStatusApplier.class);

    private final PaymentRepository payments;
    private final PaymentJournal journal;
    private final TraceContext traceContext;
    private final TransactionTemplate transaction;
    private final Clock clock;

    public PaymentStatusApplier(
            PaymentRepository payments,
            PaymentJournal journal,
            TraceContext traceContext,
            TransactionTemplate transaction,
            Clock clock) {
        this.payments = payments;
        this.journal = journal;
        this.traceContext = traceContext;
        this.transaction = transaction;
        this.clock = clock;
    }

    /**
     * Applies {@code target} to the payment; a rejected transition is journaled, never thrown. {@code failureCode} is
     * required for {@code FAILED} and not allowed otherwise.
     *
     * @throws PaymentConcurrencyConflict if the payment kept changing concurrently through every attempt
     */
    public TransitionResult apply(
            PaymentId id, PaymentStatus target, @Nullable FailureCode failureCode, EventOrigin origin) {
        for (int attempt = 1; ; attempt++) {
            try {
                return Objects.requireNonNull(transaction.execute(tx -> applyOnce(id, target, failureCode, origin)));
            } catch (PaymentConcurrencyConflict conflict) {
                if (attempt == MAX_ATTEMPTS) {
                    // No stack trace: whoever handles the rethrown conflict logs it (RC-14)
                    log.error(
                            "Status change of payment {} to {} lost after {} attempts; the payment keeps its last"
                                    + " committed status",
                            id,
                            target,
                            attempt);
                    throw conflict;
                }
                log.debug("Concurrent change of payment {}, re-applying {} (attempt {})", id, target, attempt + 1);
            }
        }
    }

    private TransitionResult applyOnce(
            PaymentId id, PaymentStatus target, @Nullable FailureCode failureCode, EventOrigin origin) {
        PaymentForChange loaded =
                payments.findForChange(id).orElseThrow(() -> new IllegalArgumentException("no payment " + id));
        Payment payment = loaded.payment();
        long sequenceNo = loaded.lastSequenceNo() + 1;
        TransitionResult result = payment.apply(target, failureCode);
        switch (result) {
            case Applied applied -> {
                payments.update(payment);
                journal.append(event(
                        id,
                        sequenceNo,
                        EventType.STATUS_CHANGED,
                        applied.from(),
                        applied.to(),
                        applied.failureCode(),
                        null,
                        origin));
                log.info("Payment {} {} -> {} (source {})", id, applied.from(), applied.to(), origin.source());
            }
            case Rejected rejected -> {
                journal.append(event(
                        id,
                        sequenceNo,
                        EventType.TRANSITION_REJECTED,
                        rejected.from(),
                        rejected.requested(),
                        rejected.requestedFailureCode(),
                        rejected.reason(),
                        origin));
                log.info(
                        "Payment {} {} -> {} rejected (source {}, reasonCode {})",
                        id,
                        rejected.from(),
                        rejected.requested(),
                        origin.source(),
                        rejected.reason().code());
            }
            case NoOp _ -> {
                // The same status with identical data: nothing to record
            }
        }
        return result;
    }

    @SuppressWarnings({"TooManyParameters", "PMD.ExcessiveParameterList"}) // one parameter per varying event field
    private PaymentEvent event(
            PaymentId id,
            long sequenceNo,
            EventType type,
            PaymentStatus from,
            PaymentStatus to,
            @Nullable FailureCode failureCode,
            @Nullable RejectionReason reason,
            EventOrigin origin) {
        return new PaymentEvent(
                UuidCreator.getTimeOrderedEpoch(),
                id,
                sequenceNo,
                type,
                from,
                to,
                failureCode,
                reason,
                origin,
                traceContext.currentTraceId(),
                Instant.now(clock));
    }
}
