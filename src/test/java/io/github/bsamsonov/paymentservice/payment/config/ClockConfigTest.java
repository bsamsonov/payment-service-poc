package io.github.bsamsonov.paymentservice.payment.config;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.ZoneOffset;
import org.junit.jupiter.api.Test;

class ClockConfigTest {

    @Test
    void applicationClockIsUtcRegardlessOfHostZone() {
        assertThat(new ClockConfig().clock().getZone()).isEqualTo(ZoneOffset.UTC);
    }
}
