create table app.counters (
  name text primary key,
  value bigint not null default 0
);

insert into app.counters (name, value) values ('project', 0);

create table app.projects (
  id bigint generated always as identity primary key,
  seq bigint not null unique,
  code text not null unique,
  name text not null check (length(btrim(name)) between 1 and 200),
  planned_start date not null,
  planned_end date not null,
  next_task_no int not null default 0,
  created_by bigint not null references app.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  check (planned_end >= planned_start)
);

create trigger projects_set_updated_at before update on app.projects
  for each row execute function app.set_updated_at();

create index projects_name_trgm_idx on app.projects using gin (name gin_trgm_ops) where deleted_at is null;
create index projects_planned_start_idx on app.projects (planned_start) where deleted_at is null;

create table app.project_stats (
  project_id bigint primary key references app.projects (id) on delete cascade,
  members_count int not null default 0,
  tasks_total int not null default 0,
  tasks_not_started int not null default 0,
  tasks_in_progress int not null default 0,
  tasks_done int not null default 0,
  tasks_blocked int not null default 0
);

create table app.project_members (
  project_id bigint not null references app.projects (id) on delete cascade,
  user_id bigint not null references app.users (id) on delete cascade,
  is_admin boolean not null default false,
  joined_at timestamptz not null default now(),
  primary key (project_id, user_id)
);

create index project_members_user_idx on app.project_members (user_id, project_id);
create index project_members_admins_idx on app.project_members (project_id) where is_admin;

create or replace function app.project_members_count() returns trigger
  language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    update app.project_stats set members_count = members_count + 1 where project_id = new.project_id;
  elsif tg_op = 'DELETE' then
    update app.project_stats set members_count = members_count - 1 where project_id = old.project_id;
  end if;
  return null;
end;
$$;

create trigger project_members_count after insert or delete on app.project_members
  for each row execute function app.project_members_count();

create type app.invitation_status as enum ('pending', 'accepted', 'rejected', 'withdrawn');

create table app.invitations (
  id bigint generated always as identity primary key,
  project_id bigint not null references app.projects (id) on delete cascade,
  invitee_id bigint not null references app.users (id) on delete cascade,
  invited_by bigint not null references app.users (id),
  status app.invitation_status not null default 'pending',
  created_at timestamptz not null default now(),
  answered_at timestamptz,
  read_at timestamptz
);

create unique index invitations_one_pending_idx on app.invitations (project_id, invitee_id) where status = 'pending';
create index invitations_invitee_idx on app.invitations (invitee_id, id desc);
create index invitations_unread_idx on app.invitations (invitee_id) where read_at is null and status <> 'withdrawn';
create index invitations_project_pending_idx on app.invitations (project_id) where status = 'pending';
