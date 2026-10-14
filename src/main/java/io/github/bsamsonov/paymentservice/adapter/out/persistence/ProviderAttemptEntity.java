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

/** Row of the append-only {@code provider_attempts} log: one call to the provider, inserted once, never updated. */
@Entity
@Table(name = "provider_attempts")
@Immutable
class ProviderAttemptEntity implements Persistable<UUID> {

    @Id
    private UUID id;

    private UUID paymentId;

    private int attemptNo;

    @Column(columnDefinition = "provider_outcome")
    private String outcome;

    private @Nullable Short providerHttpStatus;

    private @Nullable String providerCode;

    private @Nullable String providerRequestId;

    private int providerDurationMs;

    private @Nullable String traceId;

    private Instant occurredAt;

    private Instant recordedAt;

    // JPA requires a no-arg constructor; Hibernate fills the fields on load
    @SuppressWarnings("NullAway.Init")
    protected ProviderAttemptEntity() {}

    @SuppressWarnings("TooManyParameters") // one parameter per log column; built only by the journal mapper
    ProviderAttemptEntity(
            UUID id,
            UUID paymentId,
            int attemptNo,
            String outcome,
            @Nullable Short providerHttpStatus,
            @Nullable String providerCode,
            @Nullable String providerRequestId,
            int providerDurationMs,
            @Nullable String traceId,
            Instant occurredAt,
            Instant recordedAt) {
        this.id = id;
        this.paymentId = paymentId;
        this.attemptNo = attemptNo;
        this.outcome = outcome;
        this.providerHttpStatus = providerHttpStatus;
        this.providerCode = providerCode;
        this.providerRequestId = providerRequestId;
        this.providerDurationMs = providerDurationMs;
        this.traceId = traceId;
        this.occurredAt = occurredAt;
        this.recordedAt = recordedAt;
    }

    @Override
    public UUID getId() {
        return id;
    }

    /** Log rows are only ever inserted: always persist, never merge (no select before insert). */
    @Override
    @Transient
    public boolean isNew() {
        return true;
    }
}
