package io.github.bsamsonov.paymentservice.adapter.out.persistence;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import jakarta.persistence.Transient;
import java.time.Instant;
import java.util.UUID;
import org.hibernate.annotations.Immutable;
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

    @Column(columnDefinition = "payment_event_type")
    private String eventType;

    @Column(columnDefinition = "payment_status")
    private @Nullable String fromStatus;

    @Column(columnDefinition = "payment_status")
    private String toStatus;

    @Column(columnDefinition = "failure_code")
    private @Nullable String failureCode;

    private @Nullable String reasonCode;

    private String actorType;

    private String source;

    private @Nullable String traceId;

    private Instant occurredAt;

    private Instant recordedAt;

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
            String toStatus,
            @Nullable String failureCode,
            @Nullable String reasonCode,
            String actorType,
            String source,
            @Nullable String traceId,
            Instant occurredAt,
            Instant recordedAt) {
        this.id = id;
        this.paymentId = paymentId;
        this.sequenceNo = sequenceNo;
        this.eventType = eventType;
        this.fromStatus = fromStatus;
        this.toStatus = toStatus;
        this.failureCode = failureCode;
        this.reasonCode = reasonCode;
        this.actorType = actorType;
        this.source = source;
        this.traceId = traceId;
        this.occurredAt = occurredAt;
        this.recordedAt = recordedAt;
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
}
