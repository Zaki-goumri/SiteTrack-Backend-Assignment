create or replace function app.stock_json(_v app.stock_bulk) returns jsonb
  language sql immutable as $$
  select jsonb_build_object(
    'material', _v.material,
    'quantity', _v.quantity,
    'in_transit', _v.in_transit_out,
    'reorder_point', _v.reorder_point,
    'status', _v.status,
    'last_delivery_at', _v.last_delivery_at
  );
$$;

create or replace function app.stock_page(
  _store_id bigint,
  _search text,
  _category text,
  _status text,
  _sort text,
  _dir text,
  _limit int,
  _offset int
) returns jsonb language plpgsql stable set search_path = app, public as $$
declare
  _where text := 'v.store_id = $1';
  _order text;
  _out jsonb;
begin
  if _status is not null and _status not in ('out_of_stock', 'low_stock', 'available') then
    perform app.raise(422, 'status must be out_of_stock, low_stock or available');
  end if;
  if _sort not in ('name', 'quantity', 'status', 'last_delivery') then
    perform app.raise(422, 'sort must be name, quantity, status or last_delivery');
  end if;
  if _dir not in ('asc', 'desc') then
    perform app.raise(422, 'dir must be asc or desc');
  end if;
  _limit := least(greatest(coalesce(_limit, 50), 1), 200);
  _offset := greatest(coalesce(_offset, 0), 0);
  _search := nullif(btrim(_search), '');
  _category := nullif(btrim(_category), '');

  if _search is not null then _where := _where || ' and v.name ilike app.like_pattern($2)'; end if;
  if _category is not null then _where := _where || ' and v.category = $3'; end if;
  if _status is not null then _where := _where || ' and v.status = $4'; end if;

  _order := case _sort
    when 'name' then format('%%1$s.name %1$s, %%1$s.material_id %1$s', _dir)
    when 'quantity' then format('%%1$s.quantity %1$s, %%1$s.name, %%1$s.material_id', _dir)
    when 'status' then format('array_position(array[''out_of_stock'', ''low_stock'', ''available''], %%1$s.status) %1$s, %%1$s.name, %%1$s.material_id', _dir)
    else format('%%1$s.last_delivery_at %1$s nulls last, %%1$s.name, %%1$s.material_id', _dir)
  end;

  execute format($q$
    select jsonb_build_object(
      'total', (select count(*) from app.stock_bulk v where %1$s),
      'limit', $5,
      'offset', $6,
      'data', coalesce((
        select jsonb_agg(jsonb_build_object(
          'material', x.material,
          'quantity', x.quantity,
          'in_transit', x.in_transit_out,
          'reorder_point', x.reorder_point,
          'status', x.status,
          'last_delivery_at', x.last_delivery_at
        ) order by %3$s)
        from (select v.material_id from app.stock_bulk v where %1$s order by %2$s limit $5 offset $6) k
        join app.stock_bulk x on x.store_id = $1 and x.material_id = k.material_id
      ), '[]'::jsonb)
    )
  $q$, _where, format(_order, 'v'), format(_order, 'x'))
  into _out
  using _store_id, _search, _category, _status, _limit, _offset;

  return _out;
end;
$$;

create or replace function api.get_company_stock_list(
  _sid uuid,
  _search text default null,
  _category text default null,
  _status text default null,
  _sort text default 'name',
  _dir text default 'asc',
  _limit int default 50,
  _offset int default 0
) returns jsonb language plpgsql stable security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
begin
  perform app.require_store_manager(_u);
  return app.stock_page(app.company_store_id(), _search, _category, _status, _sort, _dir, _limit, _offset);
end;
$$;

create or replace function api.get_project_stock_list(
  _sid uuid,
  _code text,
  _search text default null,
  _category text default null,
  _sort text default 'name',
  _dir text default 'asc',
  _limit int default 50,
  _offset int default 0
) returns jsonb language plpgsql stable security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _p app.projects := app.require_project(_u, _code);
begin
  if _sort = 'status' then
    perform app.raise(422, 'sort must be name, quantity or last_delivery');
  end if;
  return app.stock_page(app.project_store_id(_p.id), _search, _category, null, _sort, _dir, _limit, _offset);
end;
$$;

create or replace function app.company_stock_row(_material_id bigint) returns jsonb
  language sql stable set search_path = app, public as $$
  select app.stock_json(v) from app.stock_bulk v where v.store_id = app.company_store_id() and v.material_id = _material_id;
$$;

create or replace function api.stock_add(_sid uuid, _material_id bigint, _quantity numeric, _note text default null)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _m app.materials;
begin
  perform app.require_store_manager(_u);
  _m := app.require_material(_material_id);
  perform app.check_quantity(_quantity, 'quantity');

  insert into app.stock_additions (material_id, quantity, note, added_by)
  values (_m.id, _quantity, nullif(btrim(_note), ''), _u.id);

  insert into app.stock (store_id, material_id, quantity)
  values (app.company_store_id(), _m.id, _quantity)
  on conflict (store_id, material_id) do update set quantity = app.stock.quantity + excluded.quantity;

  return app.company_stock_row(_m.id);
end;
$$;

create or replace function api.stock_set_reorder_point(_sid uuid, _material_id bigint, _reorder_point numeric)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _m app.materials;
begin
  perform app.require_store_manager(_u);
  _m := app.require_material(_material_id);
  if _reorder_point is null or _reorder_point < 0 or _reorder_point <> round(_reorder_point, 3) then
    perform app.raise(422, 'reorder_point must be 0 or more with at most 3 decimals');
  end if;

  insert into app.stock (store_id, material_id, reorder_point)
  values (app.company_store_id(), _m.id, _reorder_point)
  on conflict (store_id, material_id) do update set reorder_point = excluded.reorder_point;

  return app.company_stock_row(_m.id);
end;
$$;
