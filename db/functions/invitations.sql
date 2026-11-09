create or replace function app.notification_json(_n app.notifications_bulk)
  returns jsonb language sql immutable as $$
  select _n.invitation || jsonb_build_object(
    'project', _n.project,
    'invited_by', _n.invited_by,
    'actions', case when _n.status = 'pending' then '["accept", "reject"]'::jsonb else '[]'::jsonb end
  );
$$;

create or replace function app.unread_count(_user_id bigint)
  returns bigint language sql stable set search_path = app, public as $$
  select count(*)
  from app.invitations i
  join app.projects p on p.id = i.project_id and p.deleted_at is null
  where i.invitee_id = _user_id and i.read_at is null and i.status <> 'withdrawn';
$$;

create or replace function api.invitation_create(_sid uuid, _code text, _user_id bigint)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _p app.projects := app.require_project(_u, _code, true);
  _id bigint;
begin
  if not exists (select 1 from app.users where id = _user_id) then
    perform app.raise(404, 'user not found');
  end if;
  if exists (select 1 from app.project_members where project_id = _p.id and user_id = _user_id) then
    perform app.raise(409, 'user is already a member');
  end if;

  insert into app.invitations (project_id, invitee_id, invited_by)
  values (_p.id, _user_id, _u.id)
  on conflict (project_id, invitee_id) where status = 'pending' do nothing
  returning id into _id;

  if _id is null then
    perform app.raise(409, 'user already has a pending invitation');
  end if;

  return (
    select jsonb_build_object(
      'id', i.id,
      'user', jsonb_build_object('id', u.id, 'name', u.name, 'email', u.email),
      'invited_by', i.invited_by,
      'created_at', i.created_at
    )
    from app.invitations i
    join app.users u on u.id = i.invitee_id
    where i.id = _id
  );
end;
$$;

create or replace function api.invitation_withdraw(_sid uuid, _code text, _invitation_id bigint)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _p app.projects := app.require_project(_u, _code, true);
  _status app.invitation_status;
begin
  select status into _status
  from app.invitations
  where id = _invitation_id and project_id = _p.id
  for update;

  if _status is null then
    perform app.raise(404, 'invitation not found');
  end if;
  if _status <> 'pending' then
    perform app.raise(409, 'invitation was already answered or withdrawn');
  end if;

  update app.invitations set status = 'withdrawn', answered_at = now() where id = _invitation_id;
  return null;
end;
$$;

create or replace function api.invitation_answer(_sid uuid, _invitation_id bigint, _accept boolean)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _i app.invitations;
  _n app.notifications_bulk;
begin
  select i.* into _i
  from app.invitations i
  join app.projects p on p.id = i.project_id and p.deleted_at is null
  where i.id = _invitation_id and i.invitee_id = _u.id and i.status <> 'withdrawn'
  for update of i;

  if _i.id is null then
    perform app.raise(404, 'invitation not found');
  end if;
  if _i.status <> 'pending' then
    perform app.raise(409, 'invitation was already answered');
  end if;

  update app.invitations
  set status = case when _accept then 'accepted'::app.invitation_status else 'rejected'::app.invitation_status end,
      answered_at = now(),
      read_at = coalesce(read_at, now())
  where id = _i.id;

  if _accept then
    insert into app.project_members (project_id, user_id, is_admin)
    values (_i.project_id, _u.id, false)
    on conflict (project_id, user_id) do nothing;
  end if;

  select * into _n from app.notifications_bulk where id = _i.id;
  return app.notification_json(_n);
end;
$$;

create or replace function api.get_notifications_list(_sid uuid, _limit int default 20, _cursor bigint default null)
  returns jsonb language plpgsql stable security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _out jsonb;
begin
  _limit := least(greatest(coalesce(_limit, 20), 1), 100);

  with page as (
    select n.*
    from app.notifications_bulk n
    where n.invitee_id = _u.id and (_cursor is null or n.id < _cursor)
    order by n.id desc
    limit _limit
  )
  select jsonb_build_object(
    'data', coalesce((select jsonb_agg(app.notification_json(pg) order by pg.id desc) from page pg), '[]'::jsonb),
    'next_cursor', case when (select count(*) from page) = _limit then (select min(id) from page) end,
    'unread', app.unread_count(_u.id)
  ) into _out;

  return _out;
end;
$$;

create or replace function api.notifications_unread_count(_sid uuid)
  returns jsonb language plpgsql stable security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
begin
  return jsonb_build_object('unread', app.unread_count(_u.id));
end;
$$;

create or replace function api.notifications_mark_read(_sid uuid, _ids bigint[] default null)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
begin
  update app.invitations
  set read_at = now()
  where invitee_id = _u.id and read_at is null and (_ids is null or id = any(_ids));
  return jsonb_build_object('unread', app.unread_count(_u.id));
end;
$$;
