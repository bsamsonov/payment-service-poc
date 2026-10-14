-- Shared by every append-only table: rejects row changes and TRUNCATE with SQLSTATE 42501 (spec 001, AC-12).
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
