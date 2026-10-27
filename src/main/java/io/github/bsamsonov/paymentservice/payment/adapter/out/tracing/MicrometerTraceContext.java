package io.github.bsamsonov.paymentservice.payment.adapter.out.tracing;

import io.github.bsamsonov.paymentservice.payment.application.port.TraceContext;
import io.micrometer.tracing.Span;
import io.micrometer.tracing.Tracer;
import org.jspecify.annotations.Nullable;
import org.springframework.stereotype.Component;

@Component
class MicrometerTraceContext implements TraceContext {

    private final Tracer tracer;

    MicrometerTraceContext(Tracer tracer) {
        this.tracer = tracer;
    }

    @Override
    public @Nullable String currentTraceId() {
        @Nullable Span span = tracer.currentSpan();
        return span == null ? null : span.context().traceId();
    }
}
