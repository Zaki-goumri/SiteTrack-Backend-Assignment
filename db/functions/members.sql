create or replace function app.member_json(_project_id bigint, _user_id bigint)
  returns jsonb language sql stable set search_path = app, public as $$
  select jsonb_build_object('user', m."user", 'is_admin', m.is_admin, 'joined_at', m.joined_at)
  from app.members_bulk m
  where m.project_id = _project_id and m.user_id = _user_id;
$$;

create or replace function app.require_admin_left(_project_id bigint) returns void
  language plpgsql set search_path = app, public as $$
begin
  if not exists (select 1 from app.project_members where project_id = _project_id and is_admin) then
    perform app.raise(409, 'a project must keep at least one project admin');
  end if;
end;
$$;

create or replace function api.get_members_list(_sid uuid, _code text)
  returns jsonb language plpgsql stable security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _p app.projects := app.require_project(_u, _code);
begin
  return jsonb_build_object(
    'members', coalesce((
      select jsonb_agg(jsonb_build_object('user', m."user", 'is_admin', m.is_admin, 'joined_at', m.joined_at) order by m.is_admin desc, m.user_name, m.user_id)
      from app.members_bulk m
      where m.project_id = _p.id
    ), '[]'::jsonb),
    'pending_invitations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', i.id,
        'user', jsonb_build_object('id', u.id, 'name', u.name, 'email', u.email),
        'invited_by', i.invited_by,
        'created_at', i.created_at
      ) order by i.id desc)
      from app.invitations i
      join app.users u on u.id = i.invitee_id
      where i.project_id = _p.id and i.status = 'pending'
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function api.member_set_admin(_sid uuid, _code text, _user_id bigint, _is_admin boolean)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _p app.projects := app.require_project(_u, _code, true, true);
begin
  update app.project_members set is_admin = _is_admin where project_id = _p.id and user_id = _user_id;
  if not found then
    perform app.raise(404, 'member not found');
  end if;
  perform app.require_admin_left(_p.id);
  return app.member_json(_p.id, _user_id);
end;
$$;

create or replace function api.member_remove(_sid uuid, _code text, _user_id bigint)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _p app.projects := app.require_project(_u, _code, true, true);
begin
  delete from app.project_members where project_id = _p.id and user_id = _user_id;
  if not found then
    perform app.raise(404, 'member not found');
  end if;
  perform app.require_admin_left(_p.id);
  return null;
end;
$$;

create or replace function api.get_users_list(_sid uuid, _search text default null, _limit int default 20)
  returns jsonb language plpgsql stable security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
begin
  _limit := least(greatest(coalesce(_limit, 20), 1), 50);
  _search := nullif(btrim(_search), '');
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'email', x.email) order by x.name, x.id)
    from (
      select id, name, email
      from app.users
      where _search is null or name ilike app.like_pattern(_search) or email ilike app.like_pattern(_search)
      order by name, id
      limit _limit
    ) x
  ), '[]'::jsonb);
end;
$$;
