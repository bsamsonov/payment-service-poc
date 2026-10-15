package archfixture.good.application.port;

import archfixture.good.domain.GoodMoney;
import java.util.Optional;
import java.util.UUID;

/** Port in domain terms. */
public interface GoodPort {
    Optional<GoodMoney> find(UUID id);

    long[] totals();
}
