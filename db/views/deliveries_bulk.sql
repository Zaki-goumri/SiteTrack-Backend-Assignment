create or replace view app.deliveries_bulk as
select
  d.id,
  d.project_id,
  d.direction,
  d.status,
  d.sent_at,
  d.closed_at,
  jsonb_build_object(
    'id', d.id,
    'direction', d.direction,
    'status', d.status,
    'note', d.note,
    'sent_at', d.sent_at,
    'closed_at', d.closed_at
  ) as delivery,
  jsonb_build_object('id', p.code, 'name', p.name) as project,
  jsonb_build_object('id', su.id, 'name', su.name) as sent_by,
  case when cu.id is null then null else jsonb_build_object('id', cu.id, 'name', cu.name) end as closed_by
from app.deliveries d
join app.projects p on p.id = d.project_id
join app.users su on su.id = d.sent_by
left join app.users cu on cu.id = d.closed_by;
