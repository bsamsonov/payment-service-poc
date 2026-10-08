-- Requests rejected before a payment exists (spec 001, AC-5, AC-6). Field names and rule codes only: no values,
-- no request bodies.
create table rejected_requests (
    id                 uuid          primary key,
    trace_id           varchar(32),
    actor_type         varchar(16)   not null check (actor_type in ('CLIENT', 'PROVIDER', 'SYSTEM', 'OPERATOR')),
    actor_id           varchar(255),
    http_method        varchar(10)   not null,
    path               varchar(2048) not null,
    http_status        integer       not null check (http_status between 400 and 499),
    problem_type       varchar(255)  not null,
    error_fields       jsonb,
    external_reference varchar(100),
    occurred_at        timestamptz   not null
);

create trigger rejected_requests_append_only_rows
    before update or delete on rejected_requests
    for each row execute function forbid_append_only_change();

create trigger rejected_requests_append_only_truncate
    before truncate on rejected_requests
    for each statement execute function forbid_append_only_change();
