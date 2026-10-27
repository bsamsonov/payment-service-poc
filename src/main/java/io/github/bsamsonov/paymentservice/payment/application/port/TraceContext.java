package io.github.bsamsonov.paymentservice.payment.application.port;

import org.jspecify.annotations.Nullable;

/** The trace of the current request, for the journal rows. */
public interface TraceContext {

    /** The current trace id (32 lowercase hex characters), or null outside a trace. */
    @Nullable String currentTraceId();
}
