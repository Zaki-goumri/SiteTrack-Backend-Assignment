create or replace function app.creates_cycle(_task_id bigint, _depends_on_id bigint) returns boolean
  language sql stable set search_path = app, public as $$
  with recursive upstream(id) as (
    select d.depends_on_id from app.task_dependencies d where d.task_id = _depends_on_id
    union
    select d.depends_on_id from upstream u join app.task_dependencies d on d.task_id = u.id
  )
  select _task_id = _depends_on_id or exists (select 1 from upstream where id = _task_id);
$$;

create or replace function api.dependency_add(_sid uuid, _code text, _depends_on text)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _t app.tasks := app.require_task(_u, _code, true);
  _dep app.tasks;
begin
  select * into _dep from app.tasks where code = upper(btrim(_depends_on)) and project_id = _t.project_id;
  if _dep.id is null then
    perform app.raise(422, 'depends_on must be a task in the same project');
  end if;
  if _t.status <> 'not_started' then
    perform app.raise(409, 'dependencies can only be added to a task that has not started');
  end if;
  if app.creates_cycle(_t.id, _dep.id) then
    perform app.raise(409, 'this dependency would make the task wait on itself');
  end if;

  insert into app.task_dependencies (project_id, task_id, depends_on_id)
  values (_t.project_id, _t.id, _dep.id)
  on conflict do nothing;

  if found then
    perform app.refresh_blocked(_t.project_id);
  end if;
  return app.task_detail(_t.id);
end;
$$;

create or replace function api.dependency_remove(_sid uuid, _code text, _depends_on text)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _t app.tasks := app.require_task(_u, _code, true);
begin
  delete from app.task_dependencies d
  using app.tasks x
  where d.task_id = _t.id and d.depends_on_id = x.id and x.code = upper(btrim(_depends_on));

  if not found then
    perform app.raise(404, 'dependency not found');
  end if;

  perform app.refresh_blocked(_t.project_id);
  return app.task_detail(_t.id);
end;
$$;
