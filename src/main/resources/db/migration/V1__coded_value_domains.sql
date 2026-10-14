-- Coded values (spec 001): a closed set of codes shared by several columns is a domain over text with a named CHECK.
-- The Java enums are the source of the sets; the domain guards the stored rows, and an IT keeps the two equal.
-- A later spec extends a set with ALTER DOMAIN ... DROP CONSTRAINT / ADD CONSTRAINT; existing rows are not rewritten.
create domain payment_status as text
    constraint payment_status_values check (value in (
        'PENDING', 'PROCESSING', 'SUCCEEDED', 'FAILED', 'PARTIALLY_REFUNDED', 'REFUNDED'));

comment on domain payment_status is
    'Status of a payment. PENDING: created, the provider not called yet. PROCESSING: the provider outcome is unknown, '
    'resolved by a retry, a webhook or the reconciler. SUCCEEDED: confirmed by the provider. FAILED: declined or '
    'rejected, terminal. PARTIALLY_REFUNDED: part of the amount refunded. REFUNDED: the whole amount refunded, terminal.';

create domain failure_code as text
    constraint failure_code_values check (value in (
        'card_declined', 'insufficient_funds', 'authentication_required', 'invalid_payment_method', 'provider_error'));

comment on domain failure_code is
    'Why a payment failed. card_declined: the issuer declined. insufficient_funds: not enough funds on the card. '
    'authentication_required: customer authentication needed. invalid_payment_method: the method cannot be used. '
    'provider_error: the provider refused the request, no money moved.';

create domain payment_event_type as text
    constraint payment_event_type_values check (value in ('PAYMENT_CREATED', 'STATUS_CHANGED', 'TRANSITION_REJECTED'));

comment on domain payment_event_type is
    'What happened to a payment. PAYMENT_CREATED: created in PENDING. STATUS_CHANGED: moved to another status. '
    'TRANSITION_REJECTED: a transition was refused, the payment did not change.';

create domain provider_outcome as text
    constraint provider_outcome_values check (value in ('SUCCEEDED', 'DECLINED', 'REJECTED', 'UNKNOWN'));

comment on domain provider_outcome is
    'Result of one call to the provider. SUCCEEDED: executed. DECLINED: declined. REJECTED: definitely not executed. '
    'UNKNOWN: timeout, broken connection or 5xx, the result is not known.';
