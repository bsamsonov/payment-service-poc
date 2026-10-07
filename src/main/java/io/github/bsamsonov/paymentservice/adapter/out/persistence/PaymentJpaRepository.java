package io.github.bsamsonov.paymentservice.adapter.out.persistence;

import java.util.Optional;
import java.util.UUID;
import org.springframework.data.repository.Repository;

/**
 * Payments; no delete methods. Extends {@link Repository}, not {@code JpaRepository}, to expose only what is needed.
 */
interface PaymentJpaRepository extends Repository<PaymentEntity, UUID> {

    PaymentEntity save(PaymentEntity entity);

    Optional<PaymentEntity> findById(UUID id);
}
