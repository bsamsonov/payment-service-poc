package io.github.bsamsonov.paymentservice.adapter.out.persistence;

import java.util.UUID;
import org.springframework.data.repository.Repository;

/**
 * The provider attempts log; insert only. Extends {@link Repository}, not {@code JpaRepository}, to expose only what is
 * needed.
 */
interface ProviderAttemptJpaRepository extends Repository<ProviderAttemptEntity, UUID> {

    ProviderAttemptEntity save(ProviderAttemptEntity entity);
}
