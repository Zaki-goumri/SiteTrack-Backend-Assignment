create or replace view app.notifications_bulk as
select
  i.id,
  i.invitee_id,
  i.project_id,
  i.status,
  i.created_at,
  i.read_at,
  jsonb_build_object(
    'id', i.id,
    'type', 'project_invitation',
    'status', i.status,
    'created_at', i.created_at,
    'answered_at', i.answered_at,
    'read', i.read_at is not null
  ) as invitation,
  jsonb_build_object('id', p.code, 'name', p.name) as project,
  jsonb_build_object('id', u.id, 'name', u.name) as invited_by
from app.invitations i
join app.projects p on p.id = i.project_id and p.deleted_at is null
join app.users u on u.id = i.invited_by
where i.status <> 'withdrawn';
