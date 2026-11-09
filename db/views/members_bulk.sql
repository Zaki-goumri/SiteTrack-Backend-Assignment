create or replace view app.members_bulk as
select
  pm.project_id,
  pm.user_id,
  pm.is_admin,
  pm.joined_at,
  u.name as user_name,
  jsonb_build_object('id', u.id, 'name', u.name, 'email', u.email, 'app_role', u.app_role) as "user"
from app.project_members pm
join app.users u on u.id = pm.user_id;
