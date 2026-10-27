package io.github.bsamsonov.paymentservice.payment.adapter.out.persistence;

import java.util.Optional;
import java.util.UUID;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.Repository;

/**
 * Payments; no delete methods. Extends {@link Repository}, not {@code JpaRepository}, to expose only what is needed.
 */
interface PaymentJpaRepository extends Repository<PaymentEntity, UUID> {

    PaymentEntity save(PaymentEntity entity);

    PaymentEntity saveAndFlush(PaymentEntity entity);

    Optional<PaymentEntity> findById(UUID id);

    /**
     * The payment and its last journal sequence number in one statement, so both come from one snapshot (AC-14): a
     * decision made on this status collides with any transition committed after it.
     */
    @Query("""
            select new io.github.bsamsonov.paymentservice.payment.adapter.out.persistence.PaymentWithLastSequenceNo(
                p, coalesce((select max(e.sequenceNo) from PaymentEventEntity e where e.paymentId = p.id), 0L))
            from PaymentEntity p
            where p.id = :id""")
    Optional<PaymentWithLastSequenceNo> findWithLastSequenceNo(UUID id);
}
