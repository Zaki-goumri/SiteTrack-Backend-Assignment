create type app.app_role as enum ('user', 'store_manager', 'super_admin');

create table app.users (
  id bigint generated always as identity primary key,
  name text not null check (length(btrim(name)) between 1 and 200),
  email text not null unique check (email = lower(btrim(email)) and length(email) <= 320),
  password_hash text not null,
  app_role app.app_role not null default 'user',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger users_set_updated_at before update on app.users
  for each row execute function app.set_updated_at();

create table app.sessions (
  id uuid primary key default gen_random_uuid(),
  user_id bigint not null references app.users (id) on delete cascade,
  refresh_hash bytea not null unique,
  prev_refresh_hash bytea,
  created_at timestamptz not null default now(),
  last_used_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz
);

create index sessions_prev_refresh_hash_idx on app.sessions (prev_refresh_hash) where prev_refresh_hash is not null;
create index sessions_user_active_idx on app.sessions (user_id) where revoked_at is null;
