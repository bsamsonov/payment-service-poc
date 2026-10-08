package io.github.bsamsonov.paymentservice.adapter.out.persistence;

import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import jakarta.persistence.Transient;
import java.time.Instant;
import java.util.Map;
import java.util.UUID;
import org.hibernate.annotations.Immutable;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;
import org.jspecify.annotations.Nullable;
import org.springframework.data.domain.Persistable;

/** Row of the append-only {@code payment_events} journal: inserted once, never updated (DB trigger enforces it). */
@Entity
@Table(name = "payment_events")
@Immutable
class PaymentEventEntity implements Persistable<UUID> {

    @Id
    private UUID id;

    private UUID paymentId;

    private long sequenceNo;

    private String eventType;

    private @Nullable String fromStatus;

    private @Nullable String toStatus;

    private String actorType;

    private @Nullable String actorId;

    private String source;

    private @Nullable String reasonCode;

    private @Nullable String providerCode;

    private long amount;

    private String currency;

    private long refundedAmount;

    private @Nullable String traceId;

    private @Nullable String idempotencyKey;

    private @Nullable String requestHash;

    private @Nullable String providerEventId;

    private @Nullable Integer attemptNo;

    private @Nullable String outcome;

    private @Nullable Integer providerHttpStatus;

    private @Nullable String providerRequestId;

    private @Nullable Long providerDurationMs;

    private Instant occurredAt;

    private Instant recordedAt;

    @JdbcTypeCode(SqlTypes.JSON)
    private @Nullable Map<String, Object> details;

    // JPA requires a no-arg constructor; Hibernate fills the fields on load
    @SuppressWarnings("NullAway.Init")
    protected PaymentEventEntity() {}

    @SuppressWarnings("TooManyParameters") // one parameter per journal column; built only by the journal mapper
    PaymentEventEntity(
            UUID id,
            UUID paymentId,
            long sequenceNo,
            String eventType,
            @Nullable String fromStatus,
            @Nullable String toStatus,
            String actorType,
            @Nullable String actorId,
            String source,
            @Nullable String reasonCode,
            @Nullable String providerCode,
            long amount,
            String currency,
            long refundedAmount,
            @Nullable String traceId,
            @Nullable String idempotencyKey,
            @Nullable String requestHash,
            @Nullable String providerEventId,
            @Nullable Integer attemptNo,
            @Nullable String outcome,
            @Nullable Integer providerHttpStatus,
            @Nullable String providerRequestId,
            @Nullable Long providerDurationMs,
            Instant occurredAt,
            Instant recordedAt,
            @Nullable Map<String, Object> details) {
        this.id = id;
        this.paymentId = paymentId;
        this.sequenceNo = sequenceNo;
        this.eventType = eventType;
        this.fromStatus = fromStatus;
        this.toStatus = toStatus;
        this.actorType = actorType;
        this.actorId = actorId;
        this.source = source;
        this.reasonCode = reasonCode;
        this.providerCode = providerCode;
        this.amount = amount;
        this.currency = currency;
        this.refundedAmount = refundedAmount;
        this.traceId = traceId;
        this.idempotencyKey = idempotencyKey;
        this.requestHash = requestHash;
        this.providerEventId = providerEventId;
        this.attemptNo = attemptNo;
        this.outcome = outcome;
        this.providerHttpStatus = providerHttpStatus;
        this.providerRequestId = providerRequestId;
        this.providerDurationMs = providerDurationMs;
        this.occurredAt = occurredAt;
        this.recordedAt = recordedAt;
        this.details = details;
    }

    @Override
    public UUID getId() {
        return id;
    }

    /** Journal rows are only ever inserted: always persist, never merge (no select before insert). */
    @Override
    @Transient
    public boolean isNew() {
        return true;
    }

    @Nullable Map<String, Object> getDetails() {
        return details;
    }
}
