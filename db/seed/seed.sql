do $$
begin
  if exists (select 1 from app.users) then
    raise exception 'seed needs an empty database, run "just reset" and "just up" first';
  end if;
end;
$$;

set session_replication_role = replica;

insert into app.users (id, name, email, password_hash, app_role, created_at)
overriding system value
select
  n,
  case n
    when 1 then 'Admin'
    when 2 then 'Store Manager'
    when 3 then 'Demo User'
    else (array['Ahmed', 'Fatima', 'Omar', 'Aisha', 'Khalid', 'Maryam', 'Said', 'Noor', 'Yusuf', 'Layla',
                'Hassan', 'Sara', 'Ali', 'Huda', 'Salim', 'Reem', 'Tariq', 'Mona', 'Faisal', 'Zainab'])[1 + n % 20]
      || ' ' ||
      (array['Al Balushi', 'Al Harthy', 'Al Busaidi', 'Al Hinai', 'Al Rawahi', 'Al Lawati', 'Al Kindi', 'Al Maskari',
             'Al Farsi', 'Al Amri', 'Al Saadi', 'Al Shukaili', 'Al Riyami', 'Al Habsi', 'Al Mahrouqi'])[1 + (n / 20) % 15]
  end,
  case n
    when 1 then 'admin@sitetrack.test'
    when 2 then 'store@sitetrack.test'
    when 3 then 'user@sitetrack.test'
    else 'user' || n || '@sitetrack.test'
  end,
  '$argon2id$v=19$m=19456,t=2,p=1$taj6AJxRManGMqvHJB78eg$CW9GlMoYK17NDAz00Z1ZLVsXRR5Z6a8lDfmKDnTMYwE',
  (case
    when n = 1 or n between 4 and 20 then 'super_admin'
    when n = 2 or n between 21 and 100 then 'store_manager'
    else 'user'
  end)::app.app_role,
  timestamptz '2023-01-01' + n * interval '3 hours'
from generate_series(1, 5000) n;

insert into app.projects (id, seq, code, name, planned_start, planned_end, created_by, created_at)
overriding system value
select
  p,
  p,
  app.project_code(p),
  (array['Tower', 'Villa Complex', 'Bridge', 'Mall', 'Hospital', 'School', 'Warehouse', 'Hotel', 'Office Park', 'Road'])[1 + p % 10]
    || ' ' ||
    (array['Muscat', 'Sohar', 'Salalah', 'Nizwa', 'Sur', 'Duqm', 'Barka', 'Ibri', 'Rustaq', 'Khasab'])[1 + (p / 10) % 10]
    || ' ' || p,
  s.start,
  s.start + s.days,
  case when p <= 10 then 3 else 101 + (p * 37) % 4900 end,
  timestamptz '2023-01-01' + p * interval '10 hours'
from generate_series(1, 2000) p
cross join lateral (select date '2023-01-01' + (p * 389) % 1250 as start, 180 + (p * 53) % 720 as days) s;

update app.counters set value = 2000 where name = 'project';

insert into app.stores (kind, project_id)
select 'project', id from app.projects order by id;

insert into app.project_members (project_id, user_id, is_admin, joined_at)
select p.id, 1 + (p.id * 7919 + k * 4729) % 5000, k = 0, p.created_at + k * interval '1 day'
from app.projects p
cross join lateral generate_series(0, 2 + (p.id * 13) % 46) k
on conflict do nothing;

insert into app.project_members (project_id, user_id, is_admin, joined_at)
select id, created_by, true, created_at from app.projects
on conflict (project_id, user_id) do update set is_admin = true;

insert into app.project_members (project_id, user_id, is_admin, joined_at)
select id, 3, false, created_at from app.projects where id % 20 = 0
on conflict do nothing;

insert into app.invitations (project_id, invitee_id, invited_by, status, created_at, answered_at, read_at)
select
  p.id,
  x.invitee,
  p.created_by,
  x.status,
  x.created_at,
  case when x.status <> 'pending' then x.created_at + interval '2 days' end,
  case when x.status <> 'pending' or k % 2 = 0 then x.created_at + interval '1 day' end
from app.projects p
cross join lateral generate_series(50, 75) k
cross join lateral (
  select
    1 + (p.id * 7919 + k * 4729) % 5000 as invitee,
    (case k % 5 when 0 then 'pending' when 1 then 'pending' when 2 then 'rejected' when 3 then 'rejected' else 'withdrawn' end)::app.invitation_status as status,
    p.created_at + (k - 49) * interval '5 days' as created_at
) x
where not exists (select 1 from app.project_members m where m.project_id = p.id and m.user_id = x.invitee);

insert into app.tasks (project_id, task_no, code, name, planned_start, planned_end, status, created_at)
select
  p.id,
  n,
  app.task_code(p.code, n),
  (array['Excavation', 'Foundation pour', 'Rebar fixing', 'Formwork', 'Slab pour', 'Column casting', 'Blockwork',
         'Plastering', 'Electrical first fix', 'Plumbing first fix', 'HVAC ducting', 'Waterproofing', 'Tiling',
         'Painting', 'Facade cladding', 'Glazing', 'Roofing', 'Landscaping', 'Inspection', 'Handover prep'])[1 + n % 20]
    || ' L' || (1 + n / 20),
  p.planned_start + ((n - 1) * (p.planned_end - p.planned_start)) / c.cnt,
  p.planned_start + ((n - 1) * (p.planned_end - p.planned_start)) / c.cnt + 3 + n % 25,
  (case when n <= c.done_cut then 'done' else 'not_started' end)::app.task_status,
  p.created_at
from app.projects p
cross join lateral (
  select
    x.cnt,
    (x.cnt * least(greatest((current_date - p.planned_start)::numeric / greatest(p.planned_end - p.planned_start, 1), 0), 1) * 0.85)::int as done_cut
  from (select case when p.id <= 10 then 3000 when p.id <= 370 then 237 else 236 end as cnt) x
) c
cross join lateral generate_series(1, c.cnt) n;

update app.projects p
set next_task_no = t.cnt
from (select project_id, max(task_no) as cnt from app.tasks group by project_id) t
where t.project_id = p.id;

insert into app.task_dependencies (project_id, task_id, depends_on_id)
select t.project_id, t.id, d.id
from app.tasks t
cross join lateral (
  select
    least(t.task_no - 1, 30) as w,
    (t.id * 7) % 30 as s,
    case when t.task_no >= 4 and t.id % 50 = 0 then 3 else 2 end as k
) x
cross join lateral generate_series(0, least(x.k, x.w) - 1) j
join app.tasks d on d.project_id = t.project_id and d.task_no = t.task_no - (1 + (x.s + j) % x.w)
where t.task_no >= 2;

update app.tasks t
set status = 'in_progress'
where t.status = 'not_started'
  and t.id % 2 = 0
  and not exists (
    select 1
    from app.task_dependencies d
    join app.tasks x on x.id = d.depends_on_id
    where d.task_id = t.id and x.status <> 'done'
  );

update app.tasks
set started_at = planned_start::timestamptz,
    done_at = case when status = 'done' then planned_end::timestamptz end
where status <> 'not_started';

with recursive blocked_ids(id) as (
  select d.task_id
  from app.tasks x
  join app.task_dependencies d on d.depends_on_id = x.id
  where x.status <> 'done'
  union
  select d.task_id
  from blocked_ids b
  join app.task_dependencies d on d.depends_on_id = b.id
)
update app.tasks t
set blocked = true
from blocked_ids b
where t.id = b.id;

insert into app.project_stats (project_id, members_count, tasks_total, tasks_not_started, tasks_in_progress, tasks_done, tasks_blocked)
select
  p.id,
  coalesce(m.cnt, 0),
  coalesce(t.total, 0),
  coalesce(t.not_started, 0),
  coalesce(t.in_progress, 0),
  coalesce(t.done, 0),
  coalesce(t.blocked, 0)
from app.projects p
left join (select project_id, count(*) as cnt from app.project_members group by project_id) m on m.project_id = p.id
left join (
  select project_id,
    count(*) as total,
    count(*) filter (where status = 'not_started') as not_started,
    count(*) filter (where status = 'in_progress') as in_progress,
    count(*) filter (where status = 'done') as done,
    count(*) filter (where blocked) as blocked
  from app.tasks
  group by project_id
) t on t.project_id = p.id;

insert into app.materials (id, name, category, unit, created_at)
overriding system value
select
  n,
  c.category || ' ' || (array['Standard', 'Heavy duty', 'Premium', 'Grade A', 'Type II', 'Fine', 'Coarse', 'Large', 'Small', 'Pro'])[1 + (n / 20) % 10]
    || ' ' || lpad(n::text, 5, '0'),
  c.category,
  c.unit,
  timestamptz '2023-01-01' + n * interval '1 hour'
from generate_series(1, 20000) n
cross join lateral (
  select
    (array['Cement', 'Steel', 'Aggregates', 'Timber', 'Electrical', 'Plumbing', 'Paint', 'Tiles', 'Glass', 'Insulation',
           'Fasteners', 'Bricks', 'Roofing', 'Safety', 'Concrete', 'Waterproofing', 'Doors and Windows', 'HVAC', 'Formwork', 'Sanitary'])[1 + n % 20] as category,
    (array['bag', 'ton', 'm3', 'm3', 'pcs', 'pcs', 'litre', 'm2', 'm2', 'roll',
           'box', 'pcs', 'sheet', 'pcs', 'm3', 'roll', 'pcs', 'pcs', 'm2', 'pcs'])[1 + n % 20] as unit
) c;

insert into app.stock (store_id, material_id, quantity, reorder_point)
select
  app.company_store_id(),
  m.id,
  case when m.id % 17 = 0 then 0 else (m.id * 7919) % 5000 end,
  (m.id * 31) % 800
from app.materials m;

insert into app.stock_additions (material_id, quantity, note, added_by, added_at)
select material_id, greatest(quantity, 1), 'opening balance', 2, timestamptz '2023-01-01'
from app.stock
where store_id = app.company_store_id();

insert into app.deliveries (id, project_id, direction, status, sent_by, sent_at, closed_by, closed_at)
overriding system value
select
  i,
  x.project_id,
  x.direction,
  x.status,
  case when x.direction = 'to_project' then x.manager else p.created_by end,
  x.sent_at,
  case
    when x.status = 'in_transit' then null
    when x.status = 'cancelled' then case when x.direction = 'to_project' then x.manager else p.created_by end
    when x.direction = 'to_project' then p.created_by
    else x.manager
  end,
  case when x.status <> 'in_transit' then x.sent_at + (1 + i % 3) * interval '1 day' end
from generate_series(1, 400000) i
cross join lateral (
  select
    1 + (i * 7) % 2000 as project_id,
    (case when i % 7 = 0 then 'to_company' else 'to_project' end)::app.delivery_direction as direction,
    (case
      when i > 392000 then 'in_transit'
      when (i * 7) % 20 = 0 then 'rejected'
      when (i * 7) % 20 = 1 then 'cancelled'
      else 'delivered'
    end)::app.delivery_status as status,
    case when i % 80 = 0 then 2 else 21 + i % 80 end as manager,
    timestamptz '2023-01-01' + (now() - timestamptz '2023-01-01' - interval '1 day') * (i / 400000.0) as sent_at
) x
join app.projects p on p.id = x.project_id;

insert into app.delivery_lines (delivery_id, material_id, quantity)
select
  d.id,
  1 + (d.project_id * 97 + (d.id * 31 + j * 7) % 300) % 20000,
  case when d.direction = 'to_project' then 10 + (d.id + j * 13) % 91 else 1 + (d.id + j) % 3 end
from app.deliveries d
cross join lateral generate_series(0, 4 + d.id % 6) j;

insert into app.stock (store_id, material_id, quantity, in_transit_out, last_delivery_at)
select
  s.id,
  l.material_id,
  greatest(sum(case
    when d.direction = 'to_project' and d.status = 'delivered' then l.quantity
    when d.direction = 'to_company' and d.status in ('delivered', 'in_transit') then -l.quantity
    else 0
  end), 0),
  sum(case when d.direction = 'to_company' and d.status = 'in_transit' then l.quantity else 0 end),
  max(case
    when d.direction = 'to_project' and d.status = 'delivered' then d.closed_at
    when d.direction = 'to_company' then d.sent_at
  end)
from app.deliveries d
join app.delivery_lines l on l.delivery_id = d.id
join app.stores s on s.project_id = d.project_id
group by s.id, l.material_id;

update app.stock s
set in_transit_out = x.qty
from (
  select l.material_id, sum(l.quantity) as qty
  from app.deliveries d
  join app.delivery_lines l on l.delivery_id = d.id
  where d.direction = 'to_project' and d.status = 'in_transit'
  group by l.material_id
) x
where s.store_id = app.company_store_id() and s.material_id = x.material_id;

select setval(pg_get_serial_sequence('app.users', 'id'), (select max(id) from app.users));
select setval(pg_get_serial_sequence('app.projects', 'id'), (select max(id) from app.projects));
select setval(pg_get_serial_sequence('app.materials', 'id'), (select max(id) from app.materials));
select setval(pg_get_serial_sequence('app.deliveries', 'id'), (select max(id) from app.deliveries));

set session_replication_role = origin;

analyze;
