create or replace function app.project_detail(_u app.users, _project_id bigint)
  returns jsonb language sql stable set search_path = app, public as $$
  select jsonb_build_object('project', v.project, 'stats', v.stats, 'is_admin', coalesce(pm.is_admin, false))
  from app.projects_bulk v
  left join app.project_members pm on pm.project_id = v.id and pm.user_id = _u.id
  where v.id = _project_id;
$$;

create or replace function api.project_create(_sid uuid, _name text, _planned_start date, _planned_end date)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _seq bigint;
  _p app.projects;
begin
  if _planned_end < _planned_start then
    perform app.raise(422, 'planned_end must be on or after planned_start');
  end if;

  update app.counters set value = value + 1 where name = 'project' returning value into _seq;

  insert into app.projects (seq, code, name, planned_start, planned_end, created_by)
  values (_seq, app.project_code(_seq), btrim(_name), _planned_start, _planned_end, _u.id)
  returning * into _p;

  insert into app.project_stats (project_id) values (_p.id);
  insert into app.stores (kind, project_id) values ('project', _p.id);
  insert into app.project_members (project_id, user_id, is_admin) values (_p.id, _u.id, true);

  return app.project_detail(_u, _p.id);
end;
$$;

create or replace function api.project_get(_sid uuid, _code text)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _p app.projects := app.require_project(_u, _code);
begin
  return app.project_detail(_u, _p.id);
end;
$$;

create or replace function api.project_update(_sid uuid, _code text, _name text, _planned_start date, _planned_end date)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _p app.projects := app.require_project(_u, _code, true, true);
begin
  if coalesce(_planned_end, _p.planned_end) < coalesce(_planned_start, _p.planned_start) then
    perform app.raise(422, 'planned_end must be on or after planned_start');
  end if;

  update app.projects
  set name = coalesce(btrim(_name), name),
      planned_start = coalesce(_planned_start, planned_start),
      planned_end = coalesce(_planned_end, planned_end)
  where id = _p.id;

  return app.project_detail(_u, _p.id);
end;
$$;

create or replace function api.project_delete(_sid uuid, _code text)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _p app.projects := app.require_project(_u, _code, true, true);
begin
  if exists (select 1 from app.deliveries where project_id = _p.id and status = 'in_transit') then
    perform app.raise(409, 'project has deliveries in transit');
  end if;
  if exists (select 1 from app.stock where store_id = app.project_store_id(_p.id) and quantity > 0) then
    perform app.raise(409, 'project store still holds materials, send them back first');
  end if;
  update app.projects set deleted_at = now() where id = _p.id;
  update app.invitations set status = 'withdrawn', answered_at = now() where project_id = _p.id and status = 'pending';
  return null;
end;
$$;

create or replace function api.get_projects_list(
  _sid uuid,
  _search text default null,
  _only_late boolean default false,
  _sort text default 'name',
  _dir text default 'asc',
  _limit int default 50,
  _offset int default 0
) returns jsonb language plpgsql stable security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _out jsonb;
begin
  if _sort not in ('name', 'start', 'percent_done', 'late') then
    perform app.raise(422, 'sort must be name, start, percent_done or late');
  end if;
  if _dir not in ('asc', 'desc') then
    perform app.raise(422, 'dir must be asc or desc');
  end if;
  _limit := least(greatest(coalesce(_limit, 50), 1), 200);
  _offset := greatest(coalesce(_offset, 0), 0);
  _search := nullif(btrim(_search), '');

  with access as materialized (
    select p.id as project_id, coalesce(pm.is_admin, false) as is_admin
    from app.projects p
    left join app.project_members pm on pm.project_id = p.id and pm.user_id = _u.id
    where p.deleted_at is null and (pm.user_id is not null or _u.app_role = 'super_admin')
  ),
  filtered as (
    select v.id, v.name, v.planned_start, v.percent_done, a.is_admin,
      case when coalesce(_only_late, false) or _sort = 'late' then v.late_count end as late_count
    from app.projects_bulk v
    join access a on a.project_id = v.id
    where (_search is null or v.name ilike app.like_pattern(_search) or v.code ilike app.like_pattern(_search))
  ),
  late_filtered as (
    select f.* from filtered f where not coalesce(_only_late, false) or f.late_count > 0
  ),
  page as (
    select f.id, f.is_admin, row_number() over (order by
      case when _sort = 'name' and _dir = 'asc' then f.name end asc,
      case when _sort = 'name' and _dir = 'desc' then f.name end desc,
      case when _sort = 'start' and _dir = 'asc' then f.planned_start end asc,
      case when _sort = 'start' and _dir = 'desc' then f.planned_start end desc,
      case when _sort = 'percent_done' and _dir = 'asc' then f.percent_done end asc,
      case when _sort = 'percent_done' and _dir = 'desc' then f.percent_done end desc,
      case when _sort = 'late' and _dir = 'asc' then f.late_count end asc,
      case when _sort = 'late' and _dir = 'desc' then f.late_count end desc,
      f.id
    ) as rn
    from late_filtered f
    order by rn
    limit _limit offset _offset
  )
  select jsonb_build_object(
    'total', (select count(*) from late_filtered),
    'limit', _limit,
    'offset', _offset,
    'data', coalesce((
      select jsonb_agg(jsonb_build_object('project', v.project, 'stats', v.stats, 'is_admin', pg.is_admin) order by pg.rn)
      from page pg
      join app.projects_bulk v on v.id = pg.id
    ), '[]'::jsonb)
  ) into _out;

  return _out;
end;
$$;
