create or replace view app.tasks_bulk as
select
  t.id,
  t.project_id,
  t.task_no,
  t.code,
  t.name,
  t.status,
  t.planned_start,
  t.planned_end,
  t.blocked,
  coalesce(t.late_from < current_date, false) as is_late,
  (select count(*) from app.task_dependencies d where d.depends_on_id = t.id) as dependents_count,
  jsonb_build_object(
    'id', t.code,
    'name', t.name,
    'planned_start', t.planned_start,
    'planned_end', t.planned_end,
    'status', t.status,
    'late', coalesce(t.late_from < current_date, false),
    'blocked', t.blocked,
    'started_at', t.started_at,
    'done_at', t.done_at,
    'created_at', t.created_at
  ) as task
from app.tasks t;
