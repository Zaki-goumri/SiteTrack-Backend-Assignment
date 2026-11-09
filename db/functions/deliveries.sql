create or replace function app.delivery_is_sender(_u app.users, _project_id bigint, _direction app.delivery_direction)
  returns boolean language sql stable set search_path = app, public as $$
  select case _direction
    when 'to_project' then app.is_store_manager(_u)
    else app.can_access(_u, _project_id)
  end;
$$;

create or replace function app.delivery_is_receiver(_u app.users, _project_id bigint, _direction app.delivery_direction)
  returns boolean language sql stable set search_path = app, public as $$
  select case _direction
    when 'to_project' then app.can_access(_u, _project_id)
    else app.is_store_manager(_u)
  end;
$$;

create or replace function app.delivery_actions(_u app.users, _project_id bigint, _direction app.delivery_direction, _status app.delivery_status)
  returns jsonb language sql stable set search_path = app, public as $$
  select case when _status <> 'in_transit' then '[]'::jsonb else
    (case when app.delivery_is_sender(_u, _project_id, _direction) then '["cancel"]'::jsonb else '[]'::jsonb end)
    || (case when app.delivery_is_receiver(_u, _project_id, _direction) then '["record", "reject"]'::jsonb else '[]'::jsonb end)
  end;
$$;

create or replace function app.delivery_lines_json(_delivery_id bigint) returns jsonb
  language sql stable set search_path = app, public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'material', jsonb_build_object('id', m.id, 'name', m.name, 'category', m.category, 'unit', m.unit),
    'quantity', l.quantity
  ) order by m.name, m.id), '[]'::jsonb)
  from app.delivery_lines l
  join app.materials m on m.id = l.material_id
  where l.delivery_id = _delivery_id;
$$;

create or replace function app.delivery_json(_u app.users, _delivery_id bigint) returns jsonb
  language sql stable set search_path = app, public as $$
  select v.delivery || jsonb_build_object(
    'project', v.project,
    'sent_by', v.sent_by,
    'closed_by', v.closed_by,
    'lines', app.delivery_lines_json(v.id),
    'actions', app.delivery_actions(_u, v.project_id, v.direction, v.status)
  )
  from app.deliveries_bulk v
  where v.id = _delivery_id;
$$;

create or replace function app.check_lines(_lines jsonb) returns void
  language plpgsql stable set search_path = app, public as $$
declare
  _n int;
  _bad record;
begin
  if _lines is null or jsonb_typeof(_lines) <> 'array' then
    perform app.raise(422, 'lines must be a list');
  end if;
  _n := jsonb_array_length(_lines);
  if _n = 0 or _n > 200 then
    perform app.raise(422, 'a delivery needs 1 to 200 lines');
  end if;

  for _bad in
    select r.material_id, r.quantity from jsonb_to_recordset(_lines) as r(material_id bigint, quantity numeric)
  loop
    if _bad.material_id is null then
      perform app.raise(422, 'every line needs a material_id');
    end if;
    perform app.check_quantity(_bad.quantity, 'quantity');
  end loop;

  if (select count(distinct r.material_id) from jsonb_to_recordset(_lines) as r(material_id bigint)) <> _n then
    perform app.raise(422, 'each material can appear only once in a delivery');
  end if;

  if (
    select count(*) from jsonb_to_recordset(_lines) as r(material_id bigint)
    join app.materials m on m.id = r.material_id and m.deleted_at is null
  ) <> _n then
    perform app.raise(422, 'one or more materials do not exist');
  end if;
end;
$$;

create or replace function app.delivery_send(
  _u app.users,
  _project_id bigint,
  _direction app.delivery_direction,
  _lines jsonb,
  _note text,
  _key text
) returns jsonb language plpgsql set search_path = app, public as $$
declare
  _from bigint;
  _id bigint;
  _moved bigint[];
  _short text;
begin
  _key := nullif(btrim(_key), '');
  if _key is not null then
    select id into _id from app.deliveries where sent_by = _u.id and idempotency_key = _key;
    if _id is not null then
      return app.delivery_json(_u, _id);
    end if;
  end if;

  perform app.check_lines(_lines);
  _from := case when _direction = 'to_project' then app.company_store_id() else app.project_store_id(_project_id) end;

  perform 1
  from app.stock s
  where s.store_id = _from
    and s.material_id in (select r.material_id from jsonb_to_recordset(_lines) as r(material_id bigint))
  order by s.material_id
  for update;

  with moved as (
    update app.stock s
    set quantity = s.quantity - r.quantity,
        in_transit_out = s.in_transit_out + r.quantity,
        last_delivery_at = now()
    from jsonb_to_recordset(_lines) as r(material_id bigint, quantity numeric)
    where s.store_id = _from and s.material_id = r.material_id and s.quantity >= r.quantity
    returning s.material_id
  )
  select coalesce(array_agg(material_id), '{}') into _moved from moved;

  if cardinality(_moved) <> jsonb_array_length(_lines) then
    select m.name into _short
    from jsonb_to_recordset(_lines) as r(material_id bigint)
    join app.materials m on m.id = r.material_id
    where not (r.material_id = any(_moved))
    order by m.name
    limit 1;
    perform app.raise(409, 'not enough stock of ' || _short);
  end if;

  insert into app.deliveries (project_id, direction, sent_by, note, idempotency_key)
  values (_project_id, _direction, _u.id, nullif(btrim(_note), ''), _key)
  returning id into _id;

  insert into app.delivery_lines (delivery_id, material_id, quantity)
  select _id, r.material_id, r.quantity
  from jsonb_to_recordset(_lines) as r(material_id bigint, quantity numeric);

  return app.delivery_json(_u, _id);
end;
$$;

create or replace function api.delivery_send_to_project(_sid uuid, _code text, _lines jsonb, _note text default null, _key text default null)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _project_id bigint;
begin
  perform app.require_store_manager(_u);
  select id into _project_id from app.projects where code = upper(btrim(_code)) and deleted_at is null;
  if _project_id is null then
    perform app.raise(404, 'project not found');
  end if;
  return app.delivery_send(_u, _project_id, 'to_project', _lines, _note, _key);
end;
$$;

create or replace function api.delivery_send_to_company(_sid uuid, _code text, _lines jsonb, _note text default null, _key text default null)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _p app.projects := app.require_project(_u, _code);
begin
  return app.delivery_send(_u, _p.id, 'to_company', _lines, _note, _key);
end;
$$;

create or replace function api.delivery_close(_sid uuid, _delivery_id bigint, _action text)
  returns jsonb language plpgsql security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _d app.deliveries;
  _from bigint;
  _to bigint;
begin
  if _action not in ('record', 'reject', 'cancel') then
    perform app.raise(422, 'action must be record, reject or cancel');
  end if;

  select * into _d from app.deliveries where id = _delivery_id for update;
  if _d.id is null or not (app.is_store_manager(_u) or app.can_access(_u, _d.project_id)) then
    perform app.raise(404, 'delivery not found');
  end if;
  if _d.status <> 'in_transit' then
    perform app.raise(409, 'delivery is no longer in transit');
  end if;
  if not (app.delivery_actions(_u, _d.project_id, _d.direction, _d.status) ? _action) then
    perform app.raise(403, case _action when 'cancel' then 'only the sender can cancel this delivery' else 'only the receiver can ' || _action || ' this delivery' end);
  end if;

  if _d.direction = 'to_project' then
    _from := app.company_store_id();
    _to := app.project_store_id(_d.project_id);
  else
    _from := app.project_store_id(_d.project_id);
    _to := app.company_store_id();
  end if;

  perform 1
  from app.stock s
  join app.delivery_lines l on l.material_id = s.material_id and l.delivery_id = _d.id
  where s.store_id in (_from, _to)
  order by s.store_id, s.material_id
  for update of s;

  update app.stock s
  set in_transit_out = s.in_transit_out - l.quantity,
      quantity = s.quantity + case when _action = 'record' then 0 else l.quantity end
  from app.delivery_lines l
  where l.delivery_id = _d.id and s.store_id = _from and s.material_id = l.material_id;

  if _action = 'record' then
    insert into app.stock (store_id, material_id, quantity, last_delivery_at)
    select _to, l.material_id, l.quantity, now()
    from app.delivery_lines l
    where l.delivery_id = _d.id
    order by l.material_id
    on conflict (store_id, material_id) do update
      set quantity = app.stock.quantity + excluded.quantity,
          last_delivery_at = excluded.last_delivery_at;
  end if;

  update app.deliveries
  set status = case _action when 'record' then 'delivered' when 'reject' then 'rejected' else 'cancelled' end::app.delivery_status,
      closed_by = _u.id,
      closed_at = now()
  where id = _d.id;

  return app.delivery_json(_u, _d.id);
end;
$$;

create or replace function api.delivery_get(_sid uuid, _delivery_id bigint)
  returns jsonb language plpgsql stable security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _project_id bigint;
begin
  select project_id into _project_id from app.deliveries where id = _delivery_id;
  if _project_id is null or not (app.is_store_manager(_u) or app.can_access(_u, _project_id)) then
    perform app.raise(404, 'delivery not found');
  end if;
  return app.delivery_json(_u, _delivery_id);
end;
$$;

create or replace function api.get_deliveries_list(
  _sid uuid,
  _code text default null,
  _project text default null,
  _direction text default null,
  _status text default null,
  _from date default null,
  _to date default null,
  _limit int default 50,
  _cursor bigint default null
) returns jsonb language plpgsql stable security definer set search_path = app, public as $$
declare
  _u app.users := app.auth(_sid);
  _project_id bigint;
  _where text := 'true';
  _out jsonb;
begin
  if _direction is not null and _direction not in ('to_project', 'to_company') then
    perform app.raise(422, 'direction must be to_project or to_company');
  end if;
  if _status is not null and _status not in ('in_transit', 'delivered', 'rejected', 'cancelled') then
    perform app.raise(422, 'status must be in_transit, delivered, rejected or cancelled');
  end if;
  _limit := least(greatest(coalesce(_limit, 50), 1), 200);

  if _code is not null then
    _project_id := (app.require_project(_u, _code)).id;
  else
    perform app.require_store_manager(_u);
    if nullif(btrim(_project), '') is not null then
      select id into _project_id from app.projects where code = upper(btrim(_project));
      if _project_id is null then
        return jsonb_build_object('data', '[]'::jsonb, 'next_cursor', null);
      end if;
    end if;
  end if;

  if _project_id is not null then _where := _where || ' and v.project_id = $1'; end if;
  if _direction is not null then _where := _where || ' and v.direction = $2::app.delivery_direction'; end if;
  if _status is not null then _where := _where || ' and v.status = $3::app.delivery_status'; end if;
  if _from is not null then _where := _where || ' and v.sent_at >= $4'; end if;
  if _to is not null then _where := _where || ' and v.sent_at < $5 + 1'; end if;
  if _cursor is not null then _where := _where || ' and v.id < $6'; end if;

  execute format($q$
    with page as (
      select v.*
      from app.deliveries_bulk v
      where %s
      order by v.id desc
      limit $7
    )
    select jsonb_build_object(
      'data', coalesce((
        select jsonb_agg(pg.delivery || jsonb_build_object(
          'project', pg.project,
          'sent_by', pg.sent_by,
          'closed_by', pg.closed_by,
          'lines', app.delivery_lines_json(pg.id),
          'actions', app.delivery_actions($8, pg.project_id, pg.direction, pg.status)
        ) order by pg.id desc)
        from page pg
      ), '[]'::jsonb),
      'next_cursor', case when (select count(*) from page) = $7 then (select min(id) from page) end
    )
  $q$, _where)
  into _out
  using _project_id, _direction, _status, _from, _to, _cursor, _limit, _u;

  return _out;
end;
$$;
