-- Payments (spec 001, T7.3): "no metadata" has one form, {}, instead of both null and {} (AC-17 treats them as one
-- request). The table holds no production data yet, so this is one step; on a large table it would be split into a
-- batched backfill, a CHECK (metadata is not null) NOT VALID + VALIDATE, then SET NOT NULL.
alter table payments alter column metadata set default '{}';
update payments set metadata = '{}' where metadata is null;
alter table payments alter column metadata set not null;
