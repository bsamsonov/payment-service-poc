package io.github.bsamsonov.paymentservice.adapter.out.persistence;

import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import jakarta.persistence.Transient;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.hibernate.annotations.Immutable;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;
import org.jspecify.annotations.Nullable;
import org.springframework.data.domain.Persistable;

/** Row of the append-only {@code rejected_requests} journal: field names and rule codes, never values. */
@Entity
@Table(name = "rejected_requests")
@Immutable
class RejectedRequestEntity implements Persistable<UUID> {

    @Id
    private UUID id;

    private @Nullable String traceId;

    private String actorType;

    private @Nullable String actorId;

    private String httpMethod;

    private String path;

    private int httpStatus;

    private String problemType;

    @JdbcTypeCode(SqlTypes.JSON)
    private @Nullable List<Map<String, String>> errorFields;

    private @Nullable String externalReference;

    private Instant occurredAt;

    // JPA requires a no-arg constructor; Hibernate fills the fields on load
    @SuppressWarnings("NullAway.Init")
    protected RejectedRequestEntity() {}

    @SuppressWarnings("TooManyParameters") // one parameter per journal column; built only by the journal mapper
    RejectedRequestEntity(
            UUID id,
            @Nullable String traceId,
            String actorType,
            @Nullable String actorId,
            String httpMethod,
            String path,
            int httpStatus,
            String problemType,
            @Nullable List<Map<String, String>> errorFields,
            @Nullable String externalReference,
            Instant occurredAt) {
        this.id = id;
        this.traceId = traceId;
        this.actorType = actorType;
        this.actorId = actorId;
        this.httpMethod = httpMethod;
        this.path = path;
        this.httpStatus = httpStatus;
        this.problemType = problemType;
        this.errorFields = errorFields;
        this.externalReference = externalReference;
        this.occurredAt = occurredAt;
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

    @Nullable List<Map<String, String>> getErrorFields() {
        return errorFields;
    }
}
