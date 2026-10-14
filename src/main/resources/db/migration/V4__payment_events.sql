-- Append-only audit log of payments (spec 001, AC-10, AC-11, AC-12): what happened to a payment, who did it and when.
-- An event records the change only; the unchanging data of the payment is read from payments, which is never deleted.
-- sequence_no is max + 1 per payment; two concurrent writers collide on payment_events_sequence_unique, and the loser
-- rolls back and re-applies its transition (AC-14).
-- Column order: keys, order, what happened, why, by whom, technical fields, time.
create table payment_events (
    id           uuid               not null,
    payment_id   uuid               not null,
    sequence_no  bigint             not null,
    event_type   payment_event_type not null,
    from_status  payment_status,
    to_status    payment_status     not null,
    -- STATUS_CHANGED to FAILED: the failure code; TRANSITION_REJECTED: the requested code
    failure_code failure_code,
    reason_code  text,
    actor_type   text               not null,
    source       text               not null,
    trace_id     text,
    -- When it happened in the domain, and when this row was written
    occurred_at  timestamptz        not null,
    recorded_at  timestamptz        not null,
    constraint payment_events_pk primary key (id),
    -- No cascade: a payment with journal rows cannot be deleted
    constraint payment_events_payment_fk foreign key (payment_id) references payments (id),
    constraint payment_events_sequence_positive check (sequence_no > 0),
    constraint payment_events_sequence_unique unique (payment_id, sequence_no),
    -- Only the creation has no previous status
    constraint payment_events_from_status_present check ((event_type = 'PAYMENT_CREATED') = (from_status is null)),
    -- A failure code belongs only to FAILED; a change to FAILED always carries one
    constraint payment_events_failure_code_status check (failure_code is null or to_status = 'FAILED'),
    constraint payment_events_failed_has_code check (
        event_type <> 'STATUS_CHANGED' or to_status <> 'FAILED' or failure_code is not null),
    -- Who acted through which channel; the channel is not the operation (a refund is an event type, not a source)
    constraint payment_events_actor_source check (
        (actor_type, source) in (('CLIENT', 'API'), ('PROVIDER', 'PROVIDER_RESPONSE'))),
    constraint payment_events_trace_id_format check (trace_id ~ '^[0-9a-f]{32}$')
);

create trigger payment_events_append_only_rows
    before       update             or delete on payment_events
    for each row execute function forbid_append_only_change();

create trigger payment_events_append_only_truncate
    before       truncate           on payment_events
    for each statement execute function forbid_append_only_change();
