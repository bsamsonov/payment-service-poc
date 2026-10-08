-- Payments (spec 001). Enums are varchar + CHECK: readable in SQL, extendable by a migration.
create table payments (
    id                 uuid         primary key,
    amount             bigint       not null check (amount > 0),
    currency           varchar(3)   not null check (currency ~ '^[A-Z]{3}$'),
    payment_method_id  varchar(255) not null,
    external_reference varchar(100) not null,
    description        varchar(500),
    metadata           jsonb,
    status             varchar(32)  not null check (status in (
                           'PENDING', 'PROCESSING', 'SUCCEEDED', 'FAILED', 'PARTIALLY_REFUNDED', 'REFUNDED')),
    refunded_amount    bigint       not null default 0,
    failure_code       varchar(64)  check (failure_code in (
                           'card_declined', 'insufficient_funds', 'authentication_required',
                           'invalid_payment_method', 'provider_error')),
    request_hash       varchar(64)  not null check (request_hash ~ '^[0-9a-f]{64}$'),
    -- Counter for payment_events.sequence_no; every journal write bumps it (and the version)
    last_event_seq     bigint       not null default 0 check (last_event_seq >= 0),
    created_at         timestamptz  not null,
    updated_at         timestamptz  not null,
    version            bigint       not null,
    constraint payments_refunded_amount_range check (refunded_amount >= 0 and refunded_amount <= amount),
    -- FAILED is terminal, so the failure code is set exactly when the payment failed
    constraint payments_failure_code_status check ((status = 'FAILED') = (failure_code is not null))
);

create index payments_external_reference_created_at_idx on payments (external_reference, created_at desc);
