create schema if not exists app;
create schema if not exists api;

create extension if not exists pg_trgm with schema public;

revoke all on schema public from public;
revoke all on schema app from public;
revoke all on schema api from public;

alter default privileges revoke execute on functions from public;
alter default privileges in schema app revoke execute on functions from public;
alter default privileges in schema api revoke execute on functions from public;

create or replace function app.raise(_status int, _message text) returns void
  language plpgsql as $$
begin
  raise exception using errcode = 'ST' || _status::text, message = _message;
end;
$$;

create or replace function app.set_updated_at() returns trigger
  language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
