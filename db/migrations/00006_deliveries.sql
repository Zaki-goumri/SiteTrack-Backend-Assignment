create type app.delivery_direction as enum ('to_project', 'to_company');
create type app.delivery_status as enum ('in_transit', 'delivered', 'rejected', 'cancelled');

create table app.deliveries (
  id bigint generated always as identity primary key,
  project_id bigint not null references app.projects (id),
  direction app.delivery_direction not null,
  status app.delivery_status not null default 'in_transit',
  note text check (length(note) <= 1000),
  sent_by bigint not null references app.users (id),
  sent_at timestamptz not null default now(),
  closed_by bigint references app.users (id),
  closed_at timestamptz,
  idempotency_key text check (length(idempotency_key) <= 100),
  unique (sent_by, idempotency_key)
);

create index deliveries_project_idx on app.deliveries (project_id, id desc);
create index deliveries_sent_at_idx on app.deliveries (sent_at desc, id desc);
create index deliveries_in_transit_idx on app.deliveries (project_id, id desc) where status = 'in_transit';

create table app.delivery_lines (
  delivery_id bigint not null references app.deliveries (id) on delete cascade,
  material_id bigint not null references app.materials (id),
  quantity numeric(14, 3) not null check (quantity > 0),
  primary key (delivery_id, material_id)
);

create index delivery_lines_material_idx on app.delivery_lines (material_id);
