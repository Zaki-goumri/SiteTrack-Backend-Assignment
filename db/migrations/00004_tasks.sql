create type app.task_status as enum ('not_started', 'in_progress', 'done');

create table app.tasks (
  id bigint generated always as identity primary key,
  project_id bigint not null references app.projects (id) on delete cascade,
  task_no int not null,
  code text not null unique,
  name text not null check (length(btrim(name)) between 1 and 200),
  planned_start date not null,
  planned_end date not null,
  status app.task_status not null default 'not_started',
  blocked boolean not null default false,
  late_from date generated always as (
    case status when 'not_started' then planned_start when 'in_progress' then planned_end end
  ) stored,
  started_at timestamptz,
  done_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (project_id, task_no),
  unique (project_id, id),
  check (planned_end >= planned_start)
);

create trigger tasks_set_updated_at before update on app.tasks
  for each row execute function app.set_updated_at();

create index tasks_late_idx on app.tasks (project_id, late_from) where status <> 'done';
create index tasks_not_done_idx on app.tasks (project_id) where status <> 'done';

create table app.task_dependencies (
  project_id bigint not null,
  task_id bigint not null,
  depends_on_id bigint not null,
  created_at timestamptz not null default now(),
  primary key (task_id, depends_on_id),
  foreign key (project_id, task_id) references app.tasks (project_id, id) on delete cascade,
  foreign key (project_id, depends_on_id) references app.tasks (project_id, id) on delete cascade,
  check (task_id <> depends_on_id)
);

create index task_dependencies_depends_on_idx on app.task_dependencies (depends_on_id, task_id);

create or replace function app.tasks_stats() returns trigger
  language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    update app.project_stats s
    set tasks_total = s.tasks_total + d.total,
        tasks_not_started = s.tasks_not_started + d.not_started,
        tasks_in_progress = s.tasks_in_progress + d.in_progress,
        tasks_done = s.tasks_done + d.done,
        tasks_blocked = s.tasks_blocked + d.blocked
    from (
      select project_id,
        count(*) as total,
        count(*) filter (where status = 'not_started') as not_started,
        count(*) filter (where status = 'in_progress') as in_progress,
        count(*) filter (where status = 'done') as done,
        count(*) filter (where blocked) as blocked
      from new_rows group by project_id
    ) d
    where s.project_id = d.project_id;
  elsif tg_op = 'DELETE' then
    update app.project_stats s
    set tasks_total = s.tasks_total - d.total,
        tasks_not_started = s.tasks_not_started - d.not_started,
        tasks_in_progress = s.tasks_in_progress - d.in_progress,
        tasks_done = s.tasks_done - d.done,
        tasks_blocked = s.tasks_blocked - d.blocked
    from (
      select project_id,
        count(*) as total,
        count(*) filter (where status = 'not_started') as not_started,
        count(*) filter (where status = 'in_progress') as in_progress,
        count(*) filter (where status = 'done') as done,
        count(*) filter (where blocked) as blocked
      from old_rows group by project_id
    ) d
    where s.project_id = d.project_id;
  else
    update app.project_stats s
    set tasks_not_started = s.tasks_not_started + d.not_started,
        tasks_in_progress = s.tasks_in_progress + d.in_progress,
        tasks_done = s.tasks_done + d.done,
        tasks_blocked = s.tasks_blocked + d.blocked
    from (
      select project_id,
        sum(sign * (status = 'not_started')::int) as not_started,
        sum(sign * (status = 'in_progress')::int) as in_progress,
        sum(sign * (status = 'done')::int) as done,
        sum(sign * blocked::int) as blocked
      from (
        select project_id, status, blocked, 1 as sign from new_rows
        union all
        select project_id, status, blocked, -1 as sign from old_rows
      ) x
      group by project_id
    ) d
    where s.project_id = d.project_id
      and (d.not_started <> 0 or d.in_progress <> 0 or d.done <> 0 or d.blocked <> 0);
  end if;
  return null;
end;
$$;

create trigger tasks_stats_insert after insert on app.tasks
  referencing new table as new_rows
  for each statement execute function app.tasks_stats();

create trigger tasks_stats_update after update on app.tasks
  referencing old table as old_rows new table as new_rows
  for each statement execute function app.tasks_stats();

create trigger tasks_stats_delete after delete on app.tasks
  referencing old table as old_rows
  for each statement execute function app.tasks_stats();
