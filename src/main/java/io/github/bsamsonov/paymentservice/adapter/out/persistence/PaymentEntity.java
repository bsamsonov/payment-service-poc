package io.github.bsamsonov.paymentservice.adapter.out.persistence;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EntityListeners;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import jakarta.persistence.Version;
import java.time.Instant;
import java.util.Map;
import java.util.UUID;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;
import org.jspecify.annotations.Nullable;
import org.springframework.data.annotation.CreatedDate;
import org.springframework.data.annotation.LastModifiedDate;
import org.springframework.data.jpa.domain.support.AuditingEntityListener;

/** Row of {@code payments}. Enum columns are strings here; the mapper converts them to domain types. */
@Entity
@Table(name = "payments")
@EntityListeners(AuditingEntityListener.class)
class PaymentEntity {

    @Id
    private UUID id;

    private long amount;

    private String currency;

    private String paymentMethodId;

    private String externalReference;

    private @Nullable String description;

    @JdbcTypeCode(SqlTypes.JSON)
    private @Nullable Map<String, String> metadata;

    private String status;

    private long refundedAmount;

    private @Nullable String failureCode;

    private String requestHash;

    private long lastEventSeq;

    // Set by AuditingEntityListener before the insert
    @CreatedDate
    @Column(updatable = false)
    @SuppressWarnings("NullAway.Init")
    private Instant createdAt;

    @LastModifiedDate
    @SuppressWarnings("NullAway.Init")
    private Instant updatedAt;

    // Null until persisted: Spring Data treats the entity as new (persist, not merge) despite the assigned id
    @Version
    private @Nullable Long version;

    // JPA requires a no-arg constructor; Hibernate fills the fields on load
    @SuppressWarnings("NullAway.Init")
    protected PaymentEntity() {}

    PaymentEntity(
            UUID id,
            long amount,
            String currency,
            String paymentMethodId,
            String externalReference,
            @Nullable String description,
            @Nullable Map<String, String> metadata,
            String status,
            String requestHash) {
        this.id = id;
        this.amount = amount;
        this.currency = currency;
        this.paymentMethodId = paymentMethodId;
        this.externalReference = externalReference;
        this.description = description;
        this.metadata = metadata;
        this.status = status;
        this.requestHash = requestHash;
    }

    /** Copies the mutable state of the domain payment; each call is followed by a journal write. */
    void updateState(String status, @Nullable String failureCode, long refundedAmount, long lastEventSeq) {
        this.status = status;
        this.failureCode = failureCode;
        this.refundedAmount = refundedAmount;
        this.lastEventSeq = lastEventSeq;
    }

    UUID getId() {
        return id;
    }

    long getAmount() {
        return amount;
    }

    String getCurrency() {
        return currency;
    }

    String getPaymentMethodId() {
        return paymentMethodId;
    }

    String getExternalReference() {
        return externalReference;
    }

    @Nullable String getDescription() {
        return description;
    }

    @Nullable Map<String, String> getMetadata() {
        return metadata;
    }

    String getStatus() {
        return status;
    }

    long getRefundedAmount() {
        return refundedAmount;
    }

    @Nullable String getFailureCode() {
        return failureCode;
    }

    String getRequestHash() {
        return requestHash;
    }

    long getLastEventSeq() {
        return lastEventSeq;
    }

    Instant getCreatedAt() {
        return createdAt;
    }

    Instant getUpdatedAt() {
        return updatedAt;
    }

    @Nullable Long getVersion() {
        return version;
    }
}
