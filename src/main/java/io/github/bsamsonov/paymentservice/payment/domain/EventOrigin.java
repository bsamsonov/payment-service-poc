package io.github.bsamsonov.paymentservice.payment.domain;

/** The allowed pairs of actor and channel; the database checks the same pairs ({@code payment_events_actor_source}). */
public enum EventOrigin {
    /** A client service through our REST API. */
    CLIENT_API(ActorType.CLIENT, EventSource.API),
    /** The provider, in the response to our call. */
    PROVIDER_RESPONSE(ActorType.PROVIDER, EventSource.PROVIDER_RESPONSE);

    private final ActorType actorType;
    private final EventSource source;

    EventOrigin(ActorType actorType, EventSource source) {
        this.actorType = actorType;
        this.source = source;
    }

    public ActorType actorType() {
        return actorType;
    }

    public EventSource source() {
        return source;
    }
}
