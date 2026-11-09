create or replace view app.projects_bulk as
select
  p.id,
  p.code,
  p.name,
  p.planned_start,
  p.planned_end,
  p.created_at,
  case when s.tasks_total = 0 then 0::numeric else round(100.0 * s.tasks_done / s.tasks_total, 1) end as percent_done,
  jsonb_build_object(
    'id', p.code,
    'name', p.name,
    'planned_start', p.planned_start,
    'planned_end', p.planned_end,
    'created_at', p.created_at
  ) as project,
  jsonb_build_object(
    'members', s.members_count,
    'tasks_total', s.tasks_total,
    'tasks_not_started', s.tasks_not_started,
    'tasks_in_progress', s.tasks_in_progress,
    'tasks_done', s.tasks_done,
    'tasks_blocked', s.tasks_blocked,
    'tasks_late', (select count(*) from app.tasks t where t.project_id = p.id and t.status <> 'done' and t.late_from < current_date),
    'percent_done', case when s.tasks_total = 0 then 0::numeric else round(100.0 * s.tasks_done / s.tasks_total, 1) end
  ) as stats,
  (select count(*) from app.tasks t where t.project_id = p.id and t.status <> 'done' and t.late_from < current_date) as late_count
from app.projects p
join app.project_stats s on s.project_id = p.id
where p.deleted_at is null;
