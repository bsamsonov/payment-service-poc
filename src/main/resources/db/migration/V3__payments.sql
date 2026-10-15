-- Payments (spec 001): the current state of each payment; its history is in payment_events.
-- Column order: key, identification, money, state, optional data, technical fields, audit timestamps, version.
create table payments (
    id                 uuid           not null,
    external_reference text           not null,
    payment_method_id  text           not null,
    amount             bigint         not null,
    currency           text           not null,
    status             payment_status not null,
    failure_code       failure_code,
    description        text,
    metadata           jsonb,
    -- SHA-256 of the canonical request (AC-17)
    request_hash       text           not null,
    created_at         timestamptz    not null,
    updated_at         timestamptz    not null,
    version            bigint         not null,
    constraint payments_pk primary key (id),
    constraint payments_external_reference_length check (char_length(external_reference) between 1 and 100),
    constraint payments_amount_positive check (amount > 0),
    constraint payments_currency_format check (currency ~ '^[A-Z]{3}$'),
    -- FAILED is terminal, so the failure code is set exactly when the payment failed
    constraint payments_failure_code_status check ((status = 'FAILED') = (failure_code is not null)),
    constraint payments_description_length check (char_length(description) <= 500),
    constraint payments_metadata_object check (jsonb_typeof(metadata) = 'object'),
    constraint payments_request_hash_format check (request_hash ~ '^[0-9a-f]{64}$')
);

create index payments_external_reference_created_at_idx on payments (external_reference, created_at desc);
