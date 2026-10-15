-- Append-only log of calls to the payment provider, one row per attempt (spec 001, AC-15).
-- A technical log of the integration, kept apart from payment_events, which records what happened to the payment.
create table provider_attempts (
    id                   uuid             not null,
    payment_id           uuid             not null,
    attempt_no           integer          not null,
    outcome              provider_outcome not null,
    provider_http_status smallint,
    provider_code        text,
    -- Identifier of the call in the provider's system; not a reference to any of our tables
    provider_request_id  text,
    provider_duration_ms integer          not null,
    trace_id             text,
    -- Start of the call, and when this row was written
    occurred_at          timestamptz      not null,
    recorded_at          timestamptz      not null,
    constraint provider_attempts_pk primary key (id),
    -- No cascade: a payment with provider attempts cannot be deleted
    constraint provider_attempts_payment_fk foreign key (payment_id) references payments (id),
    constraint provider_attempts_attempt_no_positive check (attempt_no > 0),
    constraint provider_attempts_http_status_range check (provider_http_status between 100 and 599),
    constraint provider_attempts_duration_non_negative check (provider_duration_ms >= 0),
    constraint provider_attempts_trace_id_format check (trace_id ~ '^[0-9a-f]{32}$')
);

create index provider_attempts_payment_id_idx on provider_attempts (payment_id);

create trigger provider_attempts_append_only_rows
    before               update           or delete on provider_attempts
    for each row execute function forbid_append_only_change();

create trigger provider_attempts_append_only_truncate
    before               truncate         on provider_attempts
    for each statement execute function forbid_append_only_change();
