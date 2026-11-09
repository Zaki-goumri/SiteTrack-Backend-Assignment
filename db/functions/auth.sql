create or replace function api.auth_register(_name text, _email text, _password_hash text, _app_role text)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users;
begin
  if _app_role is null or _app_role not in ('user', 'store_manager', 'super_admin') then
    perform app.raise(422, 'app_role must be user, store_manager or super_admin');
  end if;

  insert into app.users (name, email, password_hash, app_role)
  values (btrim(_name), lower(btrim(_email)), _password_hash, _app_role::app.app_role)
  on conflict (email) do nothing
  returning * into _u;

  if _u.id is null then
    perform app.raise(409, 'email is already registered');
  end if;
  return app.user_json(_u);
end;
$$;

create or replace function api.auth_login_lookup(_email text)
  returns jsonb language sql stable security definer set search_path = app, public as $$
  select jsonb_build_object('user_id', u.id, 'password_hash', u.password_hash)
  from app.users u
  where u.email = lower(btrim(_email));
$$;

create or replace function api.auth_session_create(_user_id bigint, _refresh_hash bytea, _ttl_seconds int)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users;
  _sid uuid;
begin
  select * into _u from app.users where id = _user_id;
  if _u.id is null then
    perform app.raise(401, 'invalid email or password');
  end if;

  insert into app.sessions (user_id, refresh_hash, expires_at)
  values (_u.id, _refresh_hash, now() + make_interval(secs => _ttl_seconds))
  returning id into _sid;

  return jsonb_build_object('sid', _sid, 'user', app.user_json(_u));
end;
$$;

create or replace function api.auth_refresh(_refresh_hash bytea, _new_refresh_hash bytea, _ttl_seconds int)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _s app.sessions;
begin
  select * into _s from app.sessions where refresh_hash = _refresh_hash for update;

  if _s.id is null then
    update app.sessions
    set revoked_at = now()
    where prev_refresh_hash = _refresh_hash
      and revoked_at is null
      and last_used_at < now() - interval '10 seconds';
    return null;
  end if;

  if _s.revoked_at is not null or _s.expires_at <= now() then
    return null;
  end if;

  update app.sessions
  set prev_refresh_hash = refresh_hash,
      refresh_hash = _new_refresh_hash,
      last_used_at = now(),
      expires_at = now() + make_interval(secs => _ttl_seconds)
  where id = _s.id;

  return jsonb_build_object('sid', _s.id, 'user_id', _s.user_id);
end;
$$;

create or replace function api.auth_logout(_sid uuid)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
begin
  update app.sessions set revoked_at = now() where id = _sid and revoked_at is null;
  return null;
end;
$$;

create or replace function api.me(_sid uuid)
  returns jsonb language plpgsql stable security definer set search_path = app, public as $$
begin
  return app.user_json(app.auth(_sid));
end;
$$;
