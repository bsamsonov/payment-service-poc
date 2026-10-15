package archfixture.good.domain;

import java.util.List;
import org.jspecify.annotations.Nullable;

/** Plain domain type with primitives, arrays, generics and a nullable field. */
public final class GoodMoney {
    private final long amount;
    private final String currency;
    private final int[] parts;
    private final List<String> tags;
    private final @Nullable String note;

    public GoodMoney(long amount, String currency, int[] parts, List<String> tags, @Nullable String note) {
        this.amount = amount;
        this.currency = currency;
        this.parts = parts.clone();
        this.tags = List.copyOf(tags);
        this.note = note;
    }

    public boolean isPositive() {
        return amount > 0 && !currency.isEmpty() && parts.length > 0 && !tags.isEmpty() && note != null;
    }
}
