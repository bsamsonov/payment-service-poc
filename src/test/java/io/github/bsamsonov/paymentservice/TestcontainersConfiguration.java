package io.github.bsamsonov.paymentservice;

import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.context.annotation.Bean;
import org.testcontainers.postgresql.PostgreSQLContainer;

/**
 * Shared PostgreSQL for tests that start the Spring context. One container per JVM: every test context (including ones
 * with spy beans or other properties) reuses it, so a new context does not cost a new container. The bean has no
 * destroy method, so closing a context leaves the container running; Testcontainers (Ryuk) removes it at JVM exit.
 * Tests share one database: assert on the rows a test created, not on table totals.
 */
@TestConfiguration(proxyBeanMethods = false)
public class TestcontainersConfiguration {

    private static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:17");

    @Bean(destroyMethod = "")
    @ServiceConnection
    PostgreSQLContainer postgres() {
        return POSTGRES;
    }
}
