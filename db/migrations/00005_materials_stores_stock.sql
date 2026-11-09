create table app.materials (
  id bigint generated always as identity primary key,
  name text not null check (length(btrim(name)) between 1 and 200),
  category text not null check (length(btrim(category)) between 1 and 100),
  unit text not null check (length(btrim(unit)) between 1 and 30),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create trigger materials_set_updated_at before update on app.materials
  for each row execute function app.set_updated_at();

create unique index materials_name_key on app.materials (lower(name)) where deleted_at is null;
create index materials_name_idx on app.materials (name, id) where deleted_at is null;
create index materials_name_trgm_idx on app.materials using gin (name gin_trgm_ops) where deleted_at is null;
create index materials_category_idx on app.materials (category) where deleted_at is null;

create type app.store_kind as enum ('company', 'project');

create table app.stores (
  id bigint generated always as identity primary key,
  kind app.store_kind not null,
  project_id bigint unique references app.projects (id),
  check ((kind = 'company') = (project_id is null))
);

create unique index stores_one_company_idx on app.stores (kind) where kind = 'company';

insert into app.stores (kind) values ('company');
insert into app.stores (kind, project_id) select 'project', id from app.projects order by id;

create table app.stock (
  store_id bigint not null references app.stores (id),
  material_id bigint not null references app.materials (id),
  quantity numeric(14, 3) not null default 0 check (quantity >= 0),
  in_transit_out numeric(14, 3) not null default 0 check (in_transit_out >= 0),
  reorder_point numeric(14, 3) not null default 0 check (reorder_point >= 0),
  status text generated always as (
    case when quantity = 0 then 'out_of_stock' when quantity <= reorder_point then 'low_stock' else 'available' end
  ) stored,
  last_delivery_at timestamptz,
  primary key (store_id, material_id)
);

create index stock_material_idx on app.stock (material_id);
create index stock_store_status_idx on app.stock (store_id, status);

create table app.stock_additions (
  id bigint generated always as identity primary key,
  material_id bigint not null references app.materials (id),
  quantity numeric(14, 3) not null check (quantity > 0),
  note text,
  added_by bigint not null references app.users (id),
  added_at timestamptz not null default now()
);

create index stock_additions_material_idx on app.stock_additions (material_id, id desc);
