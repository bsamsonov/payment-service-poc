-- Append-only audit journal of payments (spec 001, AC-11, AC-12, AC-15).

-- Shared by every append-only table: rejects row changes and TRUNCATE with SQLSTATE 42501.
-- Protects against application bugs and manual edits, not against the table owner (who can disable triggers);
-- separate database roles are the production option.
create function forbid_append_only_change() returns trigger
    language plpgsql as
$$
begin
    raise exception using
        errcode = '42501',
        message = format('%s is append-only: %s is not allowed', tg_table_name, tg_op);
end;
$$;

create table payment_events (
    id                   uuid         primary key,
    -- No cascade: a payment with journal rows cannot be deleted
    payment_id           uuid         not null references payments (id),
    sequence_no          bigint       not null check (sequence_no > 0),
    event_type           varchar(32)  not null check (event_type in (
                             'PAYMENT_CREATED', 'STATUS_CHANGED', 'TRANSITION_REJECTED', 'PROVIDER_ATTEMPT')),
    from_status          varchar(32)  check (from_status in (
                             'PENDING', 'PROCESSING', 'SUCCEEDED', 'FAILED', 'PARTIALLY_REFUNDED', 'REFUNDED')),
    to_status            varchar(32)  check (to_status in (
                             'PENDING', 'PROCESSING', 'SUCCEEDED', 'FAILED', 'PARTIALLY_REFUNDED', 'REFUNDED')),
    actor_type           varchar(16)  not null check (actor_type in ('CLIENT', 'PROVIDER', 'SYSTEM', 'OPERATOR')),
    actor_id             varchar(255),
    source               varchar(32)  not null check (source in (
                             'API', 'PROVIDER_RESPONSE', 'WEBHOOK', 'RECONCILER', 'REFUND')),
    reason_code          varchar(64),
    provider_code        varchar(255),
    -- Snapshot of the payment after the event
    amount               bigint       not null,
    currency             varchar(3)   not null,
    refunded_amount      bigint       not null,
    trace_id             varchar(32),
    idempotency_key      varchar(255),
    request_hash         varchar(64),
    provider_event_id    varchar(255),
    -- PROVIDER_ATTEMPT only
    attempt_no           integer      check (attempt_no > 0),
    outcome              varchar(16)  check (outcome in ('SUCCEEDED', 'DECLINED', 'REJECTED', 'UNKNOWN')),
    provider_http_status integer,
    provider_request_id  varchar(255),
    provider_duration_ms bigint       check (provider_duration_ms >= 0),
    occurred_at          timestamptz  not null,
    recorded_at          timestamptz  not null,
    details              jsonb,
    constraint payment_events_sequence_unique unique (payment_id, sequence_no),
    constraint payment_events_to_status_present check (event_type = 'PROVIDER_ATTEMPT' or to_status is not null),
    constraint payment_events_attempt_fields check (
        event_type <> 'PROVIDER_ATTEMPT' or (attempt_no is not null and outcome is not null and to_status is null)),
    constraint payment_events_attempt_fields_only_on_attempts check (
        event_type = 'PROVIDER_ATTEMPT' or (attempt_no is null and outcome is null and provider_http_status is null
            and provider_request_id is null and provider_duration_ms is null))
);

create trigger payment_events_append_only_rows
    before update or delete on payment_events
    for each row execute function forbid_append_only_change();

create trigger payment_events_append_only_truncate
    before truncate on payment_events
    for each statement execute function forbid_append_only_change();
