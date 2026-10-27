package io.github.bsamsonov.paymentservice.payment.application;

import static io.github.bsamsonov.paymentservice.payment.domain.EventOrigin.PROVIDER_RESPONSE;
import static io.github.bsamsonov.paymentservice.payment.domain.FailureCode.CARD_DECLINED;
import static io.github.bsamsonov.paymentservice.payment.domain.FailureCode.INSUFFICIENT_FUNDS;
import static io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus.FAILED;
import static io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus.PENDING;
import static io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus.PROCESSING;
import static io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus.SUCCEEDED;
import static io.github.bsamsonov.paymentservice.payment.domain.RejectionReason.CONFLICTING_DUPLICATE;
import static io.github.bsamsonov.paymentservice.payment.domain.RejectionReason.TRANSITION_NOT_ALLOWED;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.clearInvocations;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;

import io.github.bsamsonov.paymentservice.TestcontainersConfiguration;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentConcurrencyConflict;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentJournal;
import io.github.bsamsonov.paymentservice.payment.application.port.PaymentRepository;
import io.github.bsamsonov.paymentservice.payment.domain.EventOrigin;
import io.github.bsamsonov.paymentservice.payment.domain.EventType;
import io.github.bsamsonov.paymentservice.payment.domain.FailureCode;
import io.github.bsamsonov.paymentservice.payment.domain.Money;
import io.github.bsamsonov.paymentservice.payment.domain.Payment;
import io.github.bsamsonov.paymentservice.payment.domain.PaymentEvent;
import io.github.bsamsonov.paymentservice.payment.domain.PaymentId;
import io.github.bsamsonov.paymentservice.payment.domain.PaymentStatus;
import io.github.bsamsonov.paymentservice.payment.domain.TransitionResult;
import io.github.bsamsonov.paymentservice.payment.domain.TransitionResult.Applied;
import io.github.bsamsonov.paymentservice.payment.domain.TransitionResult.NoOp;
import io.github.bsamsonov.paymentservice.payment.domain.TransitionResult.Rejected;
import java.time.Instant;
import java.util.Currency;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.CyclicBarrier;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;

@Import(TestcontainersConfiguration.class)
@SpringBootTest
class PaymentStatusApplierIT {

    private static final long TIMEOUT_SECONDS = 10;

    @Autowired
    private PaymentStatusApplier applier;

    @MockitoSpyBean
    private PaymentRepository payments;

    @MockitoSpyBean
    private PaymentJournal journal;

    @Autowired
    private JdbcTemplate jdbc;

    private final ExecutorService executor = Executors.newFixedThreadPool(2);

    @AfterEach
    void stopThreads() {
        executor.shutdownNow();
    }

    @Test
    @DisplayName("001/AC-11: each status change writes one event with the next sequence_no, statuses and failure code")
    void journalsEveryStatusChangeInSequence() {
        PaymentId id = storedPayment(PENDING, null);

        applier.apply(id, PROCESSING, null, PROVIDER_RESPONSE);
        applier.apply(id, FAILED, CARD_DECLINED, PROVIDER_RESPONSE);

        assertThat(events(id))
                .containsExactly(
                        created(),
                        new EventRow(
                                2,
                                "STATUS_CHANGED",
                                "PENDING",
                                "PROCESSING",
                                null,
                                null,
                                "PROVIDER",
                                "PROVIDER_RESPONSE"),
                        new EventRow(
                                3,
                                "STATUS_CHANGED",
                                "PROCESSING",
                                "FAILED",
                                "card_declined",
                                null,
                                "PROVIDER",
                                "PROVIDER_RESPONSE"));
        assertThat(paymentState(id)).isEqualTo(new PaymentRow("FAILED", "card_declined", 2));
    }

    @Test
    @DisplayName("001/AC-11: when the event insert fails, the status change is rolled back")
    void rollsBackStatusChangeWhenEventInsertFails() {
        PaymentId id = storedPayment(PENDING, null);
        doThrow(new DataAccessResourceFailureException("simulated journal failure"))
                .when(journal)
                .append(any(PaymentEvent.class));

        assertThatThrownBy(() -> applier.apply(id, SUCCEEDED, null, PROVIDER_RESPONSE))
                .isInstanceOf(DataAccessResourceFailureException.class);

        assertThat(paymentState(id)).isEqualTo(new PaymentRow("PENDING", null, 0));
        assertThat(events(id)).containsExactly(created());
    }

    @Test
    @DisplayName("001/AC-10: a transition that is not forward is journaled as rejected and the payment is unchanged")
    void journalsRejectedTransition() {
        PaymentId id = storedPayment(SUCCEEDED, null);

        TransitionResult result = applier.apply(id, PENDING, null, PROVIDER_RESPONSE);

        assertThat(result).isEqualTo(new Rejected(SUCCEEDED, PENDING, null, TRANSITION_NOT_ALLOWED));
        assertThat(events(id))
                .containsExactly(
                        created(),
                        new EventRow(
                                2,
                                "TRANSITION_REJECTED",
                                "SUCCEEDED",
                                "PENDING",
                                null,
                                "transition_not_allowed",
                                "PROVIDER",
                                "PROVIDER_RESPONSE"));
        assertThat(paymentState(id)).isEqualTo(new PaymentRow("SUCCEEDED", null, 0));
    }

    @Test
    @DisplayName("001/AC-10: a conflicting duplicate is journaled with the requested code; the payment keeps its own")
    void journalsConflictingDuplicate() {
        PaymentId id = storedPayment(FAILED, CARD_DECLINED);

        TransitionResult result = applier.apply(id, FAILED, INSUFFICIENT_FUNDS, PROVIDER_RESPONSE);

        assertThat(result).isEqualTo(new Rejected(FAILED, FAILED, INSUFFICIENT_FUNDS, CONFLICTING_DUPLICATE));
        assertThat(events(id))
                .containsExactly(
                        created(),
                        new EventRow(
                                2,
                                "TRANSITION_REJECTED",
                                "FAILED",
                                "FAILED",
                                "insufficient_funds",
                                "conflicting_duplicate",
                                "PROVIDER",
                                "PROVIDER_RESPONSE"));
        assertThat(paymentState(id)).isEqualTo(new PaymentRow("FAILED", "card_declined", 0));
    }

    @Test
    @DisplayName("001/AC-10: an identical duplicate is a no-op and writes no event")
    void identicalDuplicateWritesNothing() {
        PaymentId id = storedPayment(FAILED, CARD_DECLINED);

        TransitionResult result = applier.apply(id, FAILED, CARD_DECLINED, PROVIDER_RESPONSE);

        assertThat(result).isEqualTo(new NoOp());
        assertThat(events(id)).containsExactly(created());
        assertThat(paymentState(id)).isEqualTo(new PaymentRow("FAILED", "card_declined", 0));
    }

    @Test
    @DisplayName("001/AC-14: two concurrent changes of one PROCESSING payment: one applied, the other re-applied and"
            + " rejected, none lost")
    void concurrentStatusChangesAreNotLost() throws Exception {
        PaymentId id = storedPayment(PROCESSING, null);
        bothThreadsReadBeforeEitherWrites();

        Future<TransitionResult> succeed = executor.submit(() -> applier.apply(id, SUCCEEDED, null, PROVIDER_RESPONSE));
        Future<TransitionResult> fail =
                executor.submit(() -> applier.apply(id, FAILED, CARD_DECLINED, PROVIDER_RESPONSE));
        List<TransitionResult> results = List.of(get(succeed), get(fail));

        assertThat(results).filteredOn(Applied.class::isInstance).hasSize(1);
        assertThat(results).filteredOn(Rejected.class::isInstance).hasSize(1);
        List<EventRow> events = events(id);
        assertThat(events).extracting(EventRow::sequenceNo).containsExactly(1L, 2L, 3L);
        assertThat(events)
                .extracting(EventRow::eventType)
                .containsExactly("PAYMENT_CREATED", "STATUS_CHANGED", "TRANSITION_REJECTED");
        EventRow applied = events.get(1);
        EventRow rejected = events.get(2);
        assertThat(applied.fromStatus()).isEqualTo("PROCESSING");
        // The loser re-read the payment: it was rejected from the winner's status, not from PROCESSING
        assertThat(rejected.fromStatus()).isEqualTo(applied.toStatus());
        assertThat(paymentState(id).status()).isEqualTo(applied.toStatus());
    }

    @Test
    @DisplayName("001/AC-14: two concurrent rejected transitions collide on sequence_no and both are journaled")
    void concurrentRejectionsAreBothJournaled() throws Exception {
        PaymentId id = storedPayment(SUCCEEDED, null);
        bothThreadsReadBeforeEitherWrites();

        Future<TransitionResult> first = executor.submit(() -> applier.apply(id, PENDING, null, PROVIDER_RESPONSE));
        Future<TransitionResult> second = executor.submit(() -> applier.apply(id, PROCESSING, null, PROVIDER_RESPONSE));

        assertThat(List.of(get(first), get(second))).allMatch(Rejected.class::isInstance);
        List<EventRow> events = events(id);
        assertThat(events).extracting(EventRow::sequenceNo).containsExactly(1L, 2L, 3L);
        assertThat(events.subList(1, 3))
                .extracting(EventRow::toStatus)
                .containsExactlyInAnyOrder("PENDING", "PROCESSING");
        assertThat(paymentState(id)).isEqualTo(new PaymentRow("SUCCEEDED", null, 0));
    }

    @Test
    @DisplayName("001/AC-14: a rejection decided on a stale status collides with the committed transition and is"
            + " re-applied on the new status")
    void staleRejectionIsReappliedOnTheNewStatus() throws Exception {
        PaymentId id = storedPayment(PROCESSING, null);
        CountDownLatch staleRead = new CountDownLatch(1);
        CountDownLatch otherCommitted = new CountDownLatch(1);
        AtomicInteger reads = new AtomicInteger();
        doAnswer(invocation -> {
                    Object loaded = invocation.callRealMethod();
                    if (reads.incrementAndGet() == 1) {
                        staleRead.countDown();
                        assertThat(otherCommitted.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
                                .isTrue();
                    }
                    return loaded;
                })
                .when(payments)
                .findForChange(any());

        Future<TransitionResult> stale = executor.submit(() -> applier.apply(id, PENDING, null, PROVIDER_RESPONSE));
        assertThat(staleRead.await(TIMEOUT_SECONDS, TimeUnit.SECONDS)).isTrue();
        applier.apply(id, SUCCEEDED, null, PROVIDER_RESPONSE);
        otherCommitted.countDown();

        assertThat(get(stale)).isEqualTo(new Rejected(SUCCEEDED, PENDING, null, TRANSITION_NOT_ALLOWED));
        assertThat(events(id))
                .containsExactly(
                        created(),
                        new EventRow(
                                2,
                                "STATUS_CHANGED",
                                "PROCESSING",
                                "SUCCEEDED",
                                null,
                                null,
                                "PROVIDER",
                                "PROVIDER_RESPONSE"),
                        new EventRow(
                                3,
                                "TRANSITION_REJECTED",
                                "SUCCEEDED",
                                "PENDING",
                                null,
                                "transition_not_allowed",
                                "PROVIDER",
                                "PROVIDER_RESPONSE"));
    }

    @Test
    @DisplayName(
            "001/AC-14: a conflict that persists fails after three attempts; the payment keeps its committed state")
    void persistentConflictFailsAfterThreeAttempts() {
        PaymentId id = storedPayment(PENDING, null);
        clearInvocations(journal);
        doThrow(new PaymentConcurrencyConflict("simulated", new IllegalStateException()))
                .when(journal)
                .append(any(PaymentEvent.class));

        assertThatThrownBy(() -> applier.apply(id, SUCCEEDED, null, PROVIDER_RESPONSE))
                .isInstanceOf(PaymentConcurrencyConflict.class);

        verify(journal, times(3)).append(any(PaymentEvent.class));
        assertThat(paymentState(id)).isEqualTo(new PaymentRow("PENDING", null, 0));
    }

    /** The first read of each of the two threads waits for the other, so both decide on the same snapshot. */
    private void bothThreadsReadBeforeEitherWrites() {
        CyclicBarrier barrier = new CyclicBarrier(2);
        AtomicInteger reads = new AtomicInteger();
        doAnswer(invocation -> {
                    Object loaded = invocation.callRealMethod();
                    if (reads.incrementAndGet() <= 2) {
                        barrier.await(TIMEOUT_SECONDS, TimeUnit.SECONDS);
                    }
                    return loaded;
                })
                .when(payments)
                .findForChange(any());
    }

    private static TransitionResult get(Future<TransitionResult> result) throws Exception {
        return result.get(TIMEOUT_SECONDS, TimeUnit.SECONDS);
    }

    /** A payment in the given status, with its PAYMENT_CREATED event as sequence 1. */
    private PaymentId storedPayment(PaymentStatus status, @Nullable FailureCode failureCode) {
        PaymentId id = new PaymentId(UUID.randomUUID());
        payments.add(Payment.restore(
                id,
                new Money(1999, Currency.getInstance("USD")),
                "pm_card_visa",
                "order-" + id,
                null,
                Map.of(),
                "a".repeat(64),
                status,
                failureCode));
        journal.append(new PaymentEvent(
                UUID.randomUUID(),
                id,
                1,
                EventType.PAYMENT_CREATED,
                null,
                status,
                failureCode,
                null,
                EventOrigin.CLIENT_API,
                null,
                Instant.now()));
        return id;
    }

    private static EventRow created() {
        return new EventRow(1, "PAYMENT_CREATED", null, null, null, null, "CLIENT", "API");
    }

    private List<EventRow> events(PaymentId id) {
        return jdbc.query(
                """
                select sequence_no, event_type, from_status, to_status, failure_code, reason_code, actor_type, source
                from payment_events where payment_id = ? order by sequence_no""",
                (rs, row) -> new EventRow(
                        rs.getLong("sequence_no"),
                        rs.getString("event_type"),
                        rs.getString("from_status"),
                        // PAYMENT_CREATED is compared without its status: the helper creates payments in any status
                        rs.getLong("sequence_no") == 1 ? null : rs.getString("to_status"),
                        rs.getLong("sequence_no") == 1 ? null : rs.getString("failure_code"),
                        rs.getString("reason_code"),
                        rs.getString("actor_type"),
                        rs.getString("source")),
                id.value());
    }

    private PaymentRow paymentState(PaymentId id) {
        return jdbc.queryForObject(
                "select status, failure_code, version from payments where id = ?",
                (rs, row) ->
                        new PaymentRow(rs.getString("status"), rs.getString("failure_code"), rs.getLong("version")),
                id.value());
    }

    private record EventRow(
            long sequenceNo,
            String eventType,
            @Nullable String fromStatus,
            @Nullable String toStatus,
            @Nullable String failureCode,
            @Nullable String reasonCode,
            String actorType,
            String source) {}

    private record PaymentRow(String status, @Nullable String failureCode, long version) {}
}
