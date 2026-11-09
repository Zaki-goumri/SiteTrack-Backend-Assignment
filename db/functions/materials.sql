create or replace function app.material_json(_m app.materials) returns jsonb
  language sql immutable as $$
  select jsonb_build_object('id', _m.id, 'name', _m.name, 'category', _m.category, 'unit', _m.unit, 'created_at', _m.created_at);
$$;

create or replace function app.require_material(_material_id bigint) returns app.materials
  language plpgsql stable set search_path = app, public as $$
declare
  _m app.materials;
begin
  select * into _m from app.materials where id = _material_id and deleted_at is null;
  if _m.id is null then
    perform app.raise(404, 'material not found');
  end if;
  return _m;
end;
$$;

create or replace function api.get_materials_list(
  _sid uuid,
  _search text default null,
  _category text default null,
  _limit int default 50,
  _offset int default 0
) returns jsonb language plpgsql stable security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _out jsonb;
begin
  _limit := least(greatest(coalesce(_limit, 50), 1), 200);
  _offset := greatest(coalesce(_offset, 0), 0);
  _search := nullif(btrim(_search), '');
  _category := nullif(btrim(_category), '');

  with filtered as (
    select m.*
    from app.materials m
    where m.deleted_at is null
      and (_search is null or m.name ilike app.like_pattern(_search))
      and (_category is null or m.category = _category)
  ),
  page as (
    select f.* from filtered f order by f.name, f.id limit _limit offset _offset
  )
  select jsonb_build_object(
    'total', (select count(*) from filtered),
    'limit', _limit,
    'offset', _offset,
    'data', coalesce((
      select jsonb_agg(jsonb_build_object('id', pg.id, 'name', pg.name, 'category', pg.category, 'unit', pg.unit, 'created_at', pg.created_at) order by pg.name, pg.id)
      from page pg
    ), '[]'::jsonb)
  ) into _out;
  return _out;
end;
$$;

create or replace function api.get_material_categories(_sid uuid)
  returns jsonb language plpgsql stable security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
begin
  return coalesce((
    select jsonb_agg(c.category order by c.category)
    from (select distinct category from app.materials where deleted_at is null) c
  ), '[]'::jsonb);
end;
$$;

create or replace function api.material_get(_sid uuid, _material_id bigint)
  returns jsonb language plpgsql stable security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
begin
  return app.material_json(app.require_material(_material_id));
end;
$$;

create or replace function api.material_create(_sid uuid, _name text, _category text, _unit text)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _m app.materials;
begin
  perform app.require_store_manager(_u);
  begin
    insert into app.materials (name, category, unit)
    values (btrim(_name), btrim(_category), btrim(_unit))
    returning * into _m;
  exception when unique_violation then
    perform app.raise(409, 'a material with this name already exists');
  end;
  insert into app.stock (store_id, material_id) values (app.company_store_id(), _m.id);
  return app.material_json(_m);
end;
$$;

create or replace function api.material_update(_sid uuid, _material_id bigint, _name text, _category text, _unit text)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _m app.materials;
begin
  perform app.require_store_manager(_u);
  _m := app.require_material(_material_id);

  if _unit is not null and btrim(_unit) <> _m.unit and (
    exists (select 1 from app.stock where material_id = _m.id and (quantity > 0 or in_transit_out > 0))
    or exists (select 1 from app.delivery_lines where material_id = _m.id)
  ) then
    perform app.raise(409, 'unit cannot change once the material has stock or deliveries');
  end if;

  begin
    update app.materials
    set name = coalesce(btrim(_name), name),
        category = coalesce(btrim(_category), category),
        unit = coalesce(btrim(_unit), unit)
    where id = _m.id
    returning * into _m;
  exception when unique_violation then
    perform app.raise(409, 'a material with this name already exists');
  end;
  return app.material_json(_m);
end;
$$;

create or replace function api.material_delete(_sid uuid, _material_id bigint)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _m app.materials;
begin
  perform app.require_store_manager(_u);
  _m := app.require_material(_material_id);
  if exists (select 1 from app.stock where material_id = _m.id and (quantity > 0 or in_transit_out > 0)) then
    perform app.raise(409, 'material still has stock or deliveries in transit');
  end if;
  update app.materials set deleted_at = now() where id = _m.id;
  return null;
end;
$$;
