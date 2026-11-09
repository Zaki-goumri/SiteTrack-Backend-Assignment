create or replace function app.user_json(_u app.users) returns jsonb
  language sql immutable as $$
  select jsonb_build_object(
    'id', _u.id,
    'name', _u.name,
    'email', _u.email,
    'app_role', _u.app_role,
    'created_at', _u.created_at
  );
$$;

create or replace function app.auth(_sid uuid) returns app.users
  language plpgsql stable set search_path = app, public as $$
declare
  _u app.users;
begin
  select u.* into _u
  from app.sessions s
  join app.users u on u.id = s.user_id
  where s.id = _sid and s.revoked_at is null and s.expires_at > now();

  if _u.id is null then
    perform app.raise(401, 'session expired or logged out');
  end if;
  return _u;
end;
$$;

create or replace function app.like_pattern(_q text) returns text
  language sql immutable as $$
  select '%' || replace(replace(replace(btrim(_q), '\', '\\'), '%', '\%'), '_', '\_') || '%';
$$;

create or replace function app.project_code(_seq bigint) returns text
  language sql immutable as $$
  select 'PRJ-' || lpad(_seq::text, greatest(4, length(_seq::text)), '0');
$$;

create or replace function app.require_project_by_id(_u app.users, _project_id bigint, _admin boolean default false, _lock boolean default false)
  returns app.projects language plpgsql set search_path = app, public as $$
declare
  _p app.projects;
  _is_admin boolean;
begin
  select pm.is_admin into _is_admin
  from app.project_members pm
  where pm.project_id = _project_id and pm.user_id = _u.id;

  if _is_admin is null and _u.app_role <> 'super_admin' then
    perform app.raise(404, 'project not found');
  end if;

  if _lock then
    select * into _p from app.projects where id = _project_id and deleted_at is null for update;
  else
    select * into _p from app.projects where id = _project_id and deleted_at is null;
  end if;

  if _p.id is null then
    perform app.raise(404, 'project not found');
  end if;

  if _admin and not coalesce(_is_admin, false) and _u.app_role <> 'super_admin' then
    perform app.raise(403, 'only project admins can do this');
  end if;
  return _p;
end;
$$;

create or replace function app.require_project(_u app.users, _code text, _admin boolean default false, _lock boolean default false)
  returns app.projects language plpgsql set search_path = app, public as $$
declare
  _id bigint;
begin
  select id into _id from app.projects where code = upper(btrim(_code)) and deleted_at is null;
  if _id is null then
    perform app.raise(404, 'project not found');
  end if;
  return app.require_project_by_id(_u, _id, _admin, _lock);
end;
$$;

create or replace function app.can_access(_u app.users, _project_id bigint)
  returns boolean language sql stable set search_path = app, public as $$
  select exists (
    select 1
    from app.projects p
    where p.id = _project_id
      and p.deleted_at is null
      and (_u.app_role = 'super_admin' or exists (
        select 1 from app.project_members pm where pm.project_id = p.id and pm.user_id = _u.id
      ))
  );
$$;

create or replace function app.require_task(_u app.users, _code text, _lock boolean default false)
  returns app.tasks language plpgsql set search_path = app, public as $$
declare
  _t app.tasks;
begin
  select * into _t from app.tasks where code = upper(btrim(_code));
  if _t.id is null or not app.can_access(_u, _t.project_id) then
    perform app.raise(404, 'task not found');
  end if;
  if _lock then
    perform 1 from app.projects where id = _t.project_id for update;
    select * into _t from app.tasks where id = _t.id;
    if _t.id is null then
      perform app.raise(404, 'task not found');
    end if;
  end if;
  return _t;
end;
$$;

create or replace function app.is_store_manager(_u app.users) returns boolean
  language sql immutable as $$
  select _u.app_role in ('store_manager', 'super_admin');
$$;

create or replace function app.require_store_manager(_u app.users) returns void
  language plpgsql as $$
begin
  if not app.is_store_manager(_u) then
    perform app.raise(403, 'only company store managers can do this');
  end if;
end;
$$;

create or replace function app.company_store_id() returns bigint
  language sql stable set search_path = app, public as $$
  select id from app.stores where kind = 'company';
$$;

create or replace function app.project_store_id(_project_id bigint) returns bigint
  language sql stable set search_path = app, public as $$
  select id from app.stores where project_id = _project_id;
$$;

create or replace function app.check_quantity(_q numeric, _field text) returns void
  language plpgsql immutable as $$
begin
  if _q is null or _q <= 0 then
    perform app.raise(422, _field || ' must be greater than 0');
  end if;
  if _q <> round(_q, 3) or _q >= 100000000000 then
    perform app.raise(422, _field || ' must have at most 3 decimals and 11 whole digits');
  end if;
end;
$$;
