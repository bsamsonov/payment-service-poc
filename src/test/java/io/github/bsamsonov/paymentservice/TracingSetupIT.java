package io.github.bsamsonov.paymentservice;

import static org.assertj.core.api.Assertions.assertThat;

import io.micrometer.tracing.Tracer;
import io.micrometer.tracing.otel.bridge.OtelTracer;
import io.opentelemetry.sdk.trace.export.SpanExporter;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.micrometer.tracing.test.autoconfigure.AutoConfigureTracing;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.ApplicationContext;
import org.springframework.context.annotation.Import;

/** Tracing is on (Micrometer over the OTel bridge) but nothing is exported until spec 008. */
@Import(TestcontainersConfiguration.class)
@SpringBootTest
@AutoConfigureTracing
class TracingSetupIT {

    @Autowired
    private ApplicationContext context;

    @Test
    void tracerIsBridgedToOpenTelemetryAndNoSpanExporterIsConfigured() {
        assertThat(context.getBean(Tracer.class)).isInstanceOf(OtelTracer.class);
        assertThat(context.getBeansOfType(SpanExporter.class)).isEmpty();
    }
}
