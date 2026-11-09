create or replace view app.stock_bulk as
select
  s.store_id,
  s.material_id,
  s.quantity,
  s.in_transit_out,
  s.reorder_point,
  s.status,
  s.last_delivery_at,
  m.name,
  m.category,
  jsonb_build_object('id', m.id, 'name', m.name, 'category', m.category, 'unit', m.unit) as material
from app.stock s
join app.materials m on m.id = s.material_id
where m.deleted_at is null;
