package io.github.bsamsonov.paymentservice.adapter.out.persistence;

import java.util.Optional;
import java.util.UUID;
import org.springframework.data.repository.Repository;

/**
 * The payment journal; insert and read only. Extends {@link Repository}, not {@code JpaRepository}, to expose only what
 * is needed.
 */
interface PaymentEventJpaRepository extends Repository<PaymentEventEntity, UUID> {

    PaymentEventEntity save(PaymentEventEntity entity);

    Optional<PaymentEventEntity> findById(UUID id);
}
