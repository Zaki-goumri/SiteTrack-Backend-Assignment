create or replace function app.task_code(_project_code text, _no int) returns text
  language sql immutable as $$
  select _project_code || '-T-' || lpad(_no::text, greatest(4, length(_no::text)), '0');
$$;

create or replace function app.refresh_blocked(_project_id bigint) returns void
  language sql set search_path = app, public as $$
  with recursive blocked_ids(id) as (
    select d.task_id
    from app.tasks x
    join app.task_dependencies d on d.depends_on_id = x.id
    where x.project_id = _project_id and x.status <> 'done'
    union
    select d.task_id
    from blocked_ids b
    join app.task_dependencies d on d.depends_on_id = b.id
  ),
  target as (
    select t.id, (b.id is not null) as should_block
    from app.tasks t
    left join blocked_ids b on b.id = t.id
    where t.project_id = _project_id
  )
  update app.tasks t
  set blocked = target.should_block
  from target
  where t.id = target.id and t.blocked <> target.should_block;
$$;

create or replace function app.task_closure(_task_id bigint, _up boolean)
  returns table (node_id bigint, steps int) language plpgsql stable set search_path = app, public as $$
declare
  _frontier bigint[] := array[_task_id];
  _visited bigint[] := array[_task_id];
  _depth int := 0;
begin
  loop
    _depth := _depth + 1;
    if _up then
      select coalesce(array_agg(x.n), '{}') into _frontier
      from (
        select d.depends_on_id as n from app.task_dependencies d where d.task_id = any(_frontier)
        except
        select unnest(_visited)
      ) x;
    else
      select coalesce(array_agg(x.n), '{}') into _frontier
      from (
        select d.task_id as n from app.task_dependencies d where d.depends_on_id = any(_frontier)
        except
        select unnest(_visited)
      ) x;
    end if;
    exit when cardinality(_frontier) = 0;
    _visited := _visited || _frontier;
    return query select unnest(_frontier), _depth;
  end loop;
end;
$$;

create or replace function app.task_has_open_dependency(_task_id bigint) returns boolean
  language sql stable set search_path = app, public as $$
  select exists (
    select 1
    from app.task_dependencies d
    join app.tasks x on x.id = d.depends_on_id
    where d.task_id = _task_id and x.status <> 'done'
  );
$$;

create or replace function app.task_has_started_dependent(_task_id bigint) returns boolean
  language sql stable set search_path = app, public as $$
  select exists (
    select 1
    from app.task_dependencies d
    join app.tasks x on x.id = d.task_id
    where d.depends_on_id = _task_id and x.status <> 'not_started'
  );
$$;

create or replace function app.task_actions(_t app.tasks) returns jsonb
  language sql stable set search_path = app, public as $$
  select case _t.status
    when 'not_started' then case when app.task_has_open_dependency(_t.id) then '[]' else '["start"]' end
    when 'in_progress' then '["mark_done"]'
    when 'done' then case when app.task_has_started_dependent(_t.id) then '[]' else '["reopen"]' end
  end::jsonb;
$$;

create or replace function app.task_depends_on(_task_id bigint) returns jsonb
  language sql stable set search_path = app, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', x.code, 'name', x.name, 'status', x.status) order by x.task_no), '[]'::jsonb)
  from app.task_dependencies d
  join app.tasks x on x.id = d.depends_on_id
  where d.task_id = _task_id;
$$;

create or replace function app.task_chain(_task_id bigint, _up boolean) returns jsonb
  language sql stable set search_path = app, public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', x.code,
    'name', x.name,
    'status', x.status,
    'blocked', x.blocked,
    'late', coalesce(x.late_from < current_date, false),
    'steps', c.steps
  ) order by c.steps, x.task_no), '[]'::jsonb)
  from app.task_closure(_task_id, _up) c
  join app.tasks x on x.id = c.node_id;
$$;

create or replace function app.task_detail(_task_id bigint) returns jsonb
  language sql stable set search_path = app, public as $$
  select jsonb_build_object(
    'task', v.task,
    'project', jsonb_build_object('id', p.code, 'name', p.name),
    'actions', app.task_actions(t),
    'depends_on', app.task_depends_on(t.id),
    'dependents_count', v.dependents_count,
    'waits_on', app.task_chain(t.id, true),
    'waited_on_by', app.task_chain(t.id, false)
  )
  from app.tasks t
  join app.tasks_bulk v on v.id = t.id
  join app.projects p on p.id = t.project_id
  where t.id = _task_id;
$$;

create or replace function api.task_create(_sid uuid, _code text, _name text, _planned_start date, _planned_end date)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _p app.projects := app.require_project(_u, _code, false, true);
  _no int;
  _id bigint;
begin
  if _planned_end < _planned_start then
    perform app.raise(422, 'planned_end must be on or after planned_start');
  end if;

  update app.projects set next_task_no = next_task_no + 1 where id = _p.id returning next_task_no into _no;

  insert into app.tasks (project_id, task_no, code, name, planned_start, planned_end)
  values (_p.id, _no, app.task_code(_p.code, _no), btrim(_name), _planned_start, _planned_end)
  returning id into _id;

  return app.task_detail(_id);
end;
$$;

create or replace function api.task_get(_sid uuid, _code text)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _t app.tasks := app.require_task(_u, _code);
begin
  return app.task_detail(_t.id);
end;
$$;

create or replace function api.task_update(_sid uuid, _code text, _name text, _planned_start date, _planned_end date)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _t app.tasks := app.require_task(_u, _code);
begin
  if coalesce(_planned_end, _t.planned_end) < coalesce(_planned_start, _t.planned_start) then
    perform app.raise(422, 'planned_end must be on or after planned_start');
  end if;

  update app.tasks
  set name = coalesce(btrim(_name), name),
      planned_start = coalesce(_planned_start, planned_start),
      planned_end = coalesce(_planned_end, planned_end)
  where id = _t.id;

  return app.task_detail(_t.id);
end;
$$;

create or replace function api.task_delete(_sid uuid, _code text)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _t app.tasks := app.require_task(_u, _code, true);
begin
  delete from app.tasks where id = _t.id;
  perform app.refresh_blocked(_t.project_id);
  return null;
end;
$$;

create or replace function api.task_action(_sid uuid, _code text, _action text)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _t app.tasks := app.require_task(_u, _code, true);
begin
  case _action
    when 'start' then
      if _t.status <> 'not_started' then
        perform app.raise(409, 'only a not started task can be started');
      end if;
      if app.task_has_open_dependency(_t.id) then
        perform app.raise(409, 'task waits on tasks that are not done');
      end if;
      update app.tasks set status = 'in_progress', started_at = now() where id = _t.id;
    when 'mark_done' then
      if _t.status <> 'in_progress' then
        perform app.raise(409, 'only an in progress task can be marked as done');
      end if;
      update app.tasks set status = 'done', done_at = now() where id = _t.id;
      perform app.refresh_blocked(_t.project_id);
    when 'reopen' then
      if _t.status <> 'done' then
        perform app.raise(409, 'only a done task can be reopened');
      end if;
      if app.task_has_started_dependent(_t.id) then
        perform app.raise(409, 'a task that waits on this one has already started');
      end if;
      update app.tasks set status = 'in_progress', done_at = null where id = _t.id;
      perform app.refresh_blocked(_t.project_id);
    else
      perform app.raise(422, 'action must be start, mark_done or reopen');
  end case;

  return app.task_detail(_t.id);
end;
$$;

create or replace function api.get_tasks_list(
  _sid uuid,
  _code text,
  _status text default null,
  _late boolean default null,
  _blocked boolean default null,
  _from date default null,
  _to date default null,
  _search text default null,
  _sort text default 'id',
  _dir text default 'asc',
  _limit int default 50,
  _offset int default 0
) returns jsonb language plpgsql stable security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _p app.projects := app.require_project(_u, _code);
  _out jsonb;
begin
  if _status is not null and _status not in ('not_started', 'in_progress', 'done') then
    perform app.raise(422, 'status must be not_started, in_progress or done');
  end if;
  if _sort not in ('id', 'name', 'start', 'end', 'dependents') then
    perform app.raise(422, 'sort must be id, name, start, end or dependents');
  end if;
  if _dir not in ('asc', 'desc') then
    perform app.raise(422, 'dir must be asc or desc');
  end if;
  _limit := least(greatest(coalesce(_limit, 50), 1), 500);
  _offset := greatest(coalesce(_offset, 0), 0);
  _search := nullif(btrim(_search), '');

  with filtered as (
    select v.id, v.task_no, v.name, v.planned_start, v.planned_end,
      case when _sort = 'dependents' then v.dependents_count end as dependents_count
    from app.tasks_bulk v
    where v.project_id = _p.id
      and (_status is null or v.status = _status::app.task_status)
      and (_late is null or v.is_late = _late)
      and (_blocked is null or v.blocked = _blocked)
      and (_from is null or v.planned_end >= _from)
      and (_to is null or v.planned_start <= _to)
      and (_search is null or v.name ilike app.like_pattern(_search) or v.code ilike app.like_pattern(_search))
  ),
  page as (
    select f.id, row_number() over (order by
      case when _sort = 'id' and _dir = 'asc' then f.task_no end asc,
      case when _sort = 'id' and _dir = 'desc' then f.task_no end desc,
      case when _sort = 'name' and _dir = 'asc' then f.name end asc,
      case when _sort = 'name' and _dir = 'desc' then f.name end desc,
      case when _sort = 'start' and _dir = 'asc' then f.planned_start end asc,
      case when _sort = 'start' and _dir = 'desc' then f.planned_start end desc,
      case when _sort = 'end' and _dir = 'asc' then f.planned_end end asc,
      case when _sort = 'end' and _dir = 'desc' then f.planned_end end desc,
      case when _sort = 'dependents' and _dir = 'asc' then f.dependents_count end asc,
      case when _sort = 'dependents' and _dir = 'desc' then f.dependents_count end desc,
      f.task_no
    ) as rn
    from filtered f
    order by rn
    limit _limit offset _offset
  )
  select jsonb_build_object(
    'total', (select count(*) from filtered),
    'limit', _limit,
    'offset', _offset,
    'data', coalesce((
      select jsonb_agg(v.task || jsonb_build_object('depends_on', app.task_depends_on(v.id), 'dependents_count', v.dependents_count) order by pg.rn)
      from page pg
      join app.tasks_bulk v on v.id = pg.id
    ), '[]'::jsonb)
  ) into _out;

  return _out;
end;
$$;
