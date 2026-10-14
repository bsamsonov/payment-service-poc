-- Reference tables (spec 001): every coded value used by more than one table, or meaningful to a reader, is data
-- with a description. Columns refer to them by foreign key; the code is the natural key, so reads need no join.
-- Later specs add rows by INSERT in their own migrations. The Java enums mirror these rows; a test keeps them equal.
create table payment_statuses (
    code        text primary key,
    description text not null
);

insert into payment_statuses (code, description) values
    ('PENDING',            'Created, the provider has not been called yet'),
    ('PROCESSING',         'The provider outcome is unknown; resolved by a retry, a webhook or the reconciler'),
    ('SUCCEEDED',          'The provider confirmed the payment'),
    ('FAILED',             'The provider declined or rejected the payment; terminal'),
    ('PARTIALLY_REFUNDED', 'Part of the amount was refunded'),
    ('REFUNDED',           'The whole amount was refunded; terminal');

create table failure_codes (
    code        text primary key,
    description text not null
);

insert into failure_codes (code, description) values
    ('card_declined',           'The card issuer declined the payment'),
    ('insufficient_funds',      'Not enough funds on the card'),
    ('authentication_required', 'The payment needs customer authentication'),
    ('invalid_payment_method',  'The payment method cannot be used'),
    ('provider_error',          'The provider refused the request; no money moved');

create table payment_event_types (
    code        text primary key,
    description text not null
);

insert into payment_event_types (code, description) values
    ('PAYMENT_CREATED',     'The payment was created in PENDING'),
    ('STATUS_CHANGED',      'The payment moved to another status'),
    ('TRANSITION_REJECTED', 'A transition was refused; the payment did not change');

create table actor_types (
    code        text primary key,
    description text not null
);

insert into actor_types (code, description) values
    ('CLIENT',   'The API client that owns the payment'),
    ('PROVIDER', 'The payment provider');

-- The channel an event came through. An operation (such as a refund) is an event type, not a source.
create table event_sources (
    code        text primary key,
    description text not null
);

insert into event_sources (code, description) values
    ('API',               'A request to this service''s API'),
    ('PROVIDER_RESPONSE', 'The response to our call to the provider');

-- Which actor can act through which channel; payment_events refers to a pair, so nonsense pairs are impossible.
create table actor_sources (
    actor_type text not null,
    source     text not null,
    constraint actor_sources_pk primary key (actor_type, source),
    constraint actor_sources_actor_type_fk foreign key (actor_type) references actor_types (code),
    constraint actor_sources_source_fk foreign key (source) references event_sources (code)
);

insert into actor_sources (actor_type, source) values
    ('CLIENT',   'API'),
    ('PROVIDER', 'PROVIDER_RESPONSE');

create table provider_outcomes (
    code        text primary key,
    description text not null
);

insert into provider_outcomes (code, description) values
    ('SUCCEEDED', 'The provider executed the payment'),
    ('DECLINED',  'The provider declined the payment'),
    ('REJECTED',  'The provider definitely did not execute the request'),
    ('UNKNOWN',   'Timeout, broken connection or 5xx: the result is not known');
