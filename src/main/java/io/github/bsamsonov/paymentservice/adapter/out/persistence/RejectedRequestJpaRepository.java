package io.github.bsamsonov.paymentservice.adapter.out.persistence;

import java.util.Optional;
import java.util.UUID;
import org.springframework.data.repository.Repository;

/**
 * Rejected requests journal; insert and read only. Extends {@link Repository}, not {@code JpaRepository}, to expose
 * only what is needed.
 */
interface RejectedRequestJpaRepository extends Repository<RejectedRequestEntity, UUID> {

    RejectedRequestEntity save(RejectedRequestEntity entity);

    Optional<RejectedRequestEntity> findById(UUID id);
}
