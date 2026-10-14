-- Mjesta života osobe (poredani popis, uz neobaveznu godinu): persons.places = [{"p":"Melina"},{"p":"Australija","y":"1975"}]
-- (Nepoznata godina smrti: stupac died ima vrijednost '?', za to nije potrebna promjena baze.)
-- Sigurno za ponovno pokretanje.

alter table public.persons add column if not exists places jsonb
  constraint persons_places_check check (places is null or (jsonb_typeof(places) = 'array' and jsonb_array_length(places) <= 30));

-- povijest izmjena: bilježi i promjenu mjesta
create or replace function public.persons_audit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.name is distinct from old.name then
    insert into person_history(person_id, field, old_value, new_value, changed_by) values (old.id, 'name', old.name, new.name, auth.uid()); end if;
  if new.born is distinct from old.born then
    insert into person_history(person_id, field, old_value, new_value, changed_by) values (old.id, 'born', old.born, new.born, auth.uid()); end if;
  if new.died is distinct from old.died then
    insert into person_history(person_id, field, old_value, new_value, changed_by) values (old.id, 'died', old.died, new.died, auth.uid()); end if;
  if new.info is distinct from old.info then
    insert into person_history(person_id, field, old_value, new_value, changed_by) values (old.id, 'info', old.info, new.info, auth.uid()); end if;
  if new.places is distinct from old.places then
    insert into person_history(person_id, field, old_value, new_value, changed_by) values (old.id, 'places', old.places::text, new.places::text, auth.uid()); end if;
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;


-- get_tree(): osoba sada nosi i 'places'
create or replace function public.get_tree() returns jsonb
language sql stable as $$
  with p as (select * from public.persons where deleted_at is null)
  select jsonb_build_object(
    'persons', coalesce((select jsonb_object_agg(id, jsonb_strip_nulls(jsonb_build_object('n', name, 'born', born, 'died', died, 'info', info, 'anchor', case when age_anchor then true end, 'eldest', case when is_eldest then true end, 'color', color, 'places', places))) from p), '{}'::jsonb),
    'marriages', coalesce((select jsonb_agg(jsonb_build_array(m.person_a, m.person_b) order by m.id) from public.marriages m where m.person_a in (select id from p) and m.person_b in (select id from p)), '[]'::jsonb),
    'parents',   coalesce((select jsonb_agg(jsonb_build_array(c.parent_id, c.child_id) order by c.ord) from public.parent_child c where c.parent_id in (select id from p) and c.child_id in (select id from p)), '[]'::jsonb),
    'positions', coalesce((select jsonb_object_agg(id, jsonb_build_object('x', x, 'y', y)) from p where x is not null and y is not null), '{}'::jsonb)
  )
$$;
grant execute on function public.get_tree() to authenticated;

-- add_relative(): novi parametar p_places (stara verzija bez njega se uklanja)
drop function if exists public.add_relative(text, text, text, text, text, text, text, text);
create or replace function public.add_relative(
  p_anchor text, p_relation text, p_name text,
  p_born text default null, p_died text default null, p_info text default null,
  p_other_parent text default null, p_color text default null,
  p_places jsonb default null
) returns text
language plpgsql set search_path = public as $$
declare
  a persons%rowtype; o persons%rowtype;
  nid text := gen_random_uuid()::text;
  nm text := nullif(btrim(p_name), '');
  col text; nparents int; ph_id text;
  outward double precision; base double precision;
  sp record; ph_sp record;
  np jsonb := case when jsonb_typeof(p_places) = 'array' and jsonb_array_length(p_places) > 0 then p_places end;
begin
  if not public.is_admin() then raise exception 'Samo admin može dodavati osobe.'; end if;
  if nm is null then raise exception 'Ime je obavezno.'; end if;
  if p_relation not in ('spouse','child','parent','sibling') then raise exception 'Nepoznata vrsta veze.'; end if;
  if p_color is not null and p_color !~ '^#[0-9a-fA-F]{6}$' then raise exception 'Neispravna boja.'; end if;
  select * into a from persons where id = p_anchor and deleted_at is null;
  if not found then raise exception 'Osoba nije pronađena.'; end if;
  if p_other_parent is not null and p_relation <> 'child' then raise exception 'Drugi roditelj vrijedi samo za dijete.'; end if;

  col := lower(coalesce(p_color, a.color, '#cfd6e0'));
  outward := atan2(coalesce(a.y, 0), coalesce(a.x, 0));

  if p_relation = 'spouse' then
    base := outward + pi() / 2;
    select * into sp from public.free_spot(a.x, a.y, base);
    insert into persons (id, name, born, died, info, x, y, color, places)
      values (nid, nm, nullif(btrim(p_born),''), nullif(btrim(p_died),''), nullif(btrim(p_info),''), sp.fx, sp.fy, col, np);
    insert into marriages (person_a, person_b) values (a.id, nid);

  elsif p_relation = 'child' then
    if p_other_parent is not null then
      select * into o from persons where id = p_other_parent and deleted_at is null;
      if not found then raise exception 'Drugi roditelj nije pronađen.'; end if;
      if o.id = a.id then raise exception 'Drugi roditelj mora biti druga osoba.'; end if;
    end if;
    base := outward;
    select * into sp from public.free_spot(a.x, a.y, base);
    insert into persons (id, name, born, died, info, x, y, color, places)
      values (nid, nm, nullif(btrim(p_born),''), nullif(btrim(p_died),''), nullif(btrim(p_info),''), sp.fx, sp.fy, col, np);
    insert into parent_child (parent_id, child_id) values (a.id, nid);
    if o.id is not null then insert into parent_child (parent_id, child_id) values (o.id, nid); end if;

  elsif p_relation = 'parent' then
    select count(*) into nparents from parent_child pc join persons q on q.id = pc.parent_id and q.deleted_at is null where pc.child_id = a.id;
    if nparents >= 2 then raise exception 'Osoba već ima dva roditelja.'; end if;
    base := outward + pi();
    select * into sp from public.free_spot(a.x, a.y, base);
    insert into persons (id, name, born, died, info, x, y, color, places)
      values (nid, nm, nullif(btrim(p_born),''), nullif(btrim(p_died),''), nullif(btrim(p_info),''), sp.fx, sp.fy, col, np);
    insert into parent_child (parent_id, child_id) values (nid, a.id);

  else  -- sibling
    base := outward + pi() / 2;
    select * into sp from public.free_spot(a.x, a.y, base);
    insert into persons (id, name, born, died, info, x, y, color, places)
      values (nid, nm, nullif(btrim(p_born),''), nullif(btrim(p_died),''), nullif(btrim(p_info),''), sp.fx, sp.fy, col, np);
    if exists (select 1 from parent_child pc join persons q on q.id = pc.parent_id and q.deleted_at is null where pc.child_id = a.id) then
      insert into parent_child (parent_id, child_id)
        select pc.parent_id, nid from parent_child pc join persons q on q.id = pc.parent_id and q.deleted_at is null where pc.child_id = a.id;
    else
      -- nepoznati roditelji: čvor-rezerva da braća i sestre ostanu povezani
      ph_id := gen_random_uuid()::text;
      select * into ph_sp from public.free_spot(a.x, a.y, outward + pi());
      insert into persons (id, name, x, y, color) values (ph_id, 'roditelji (nepoznati)', ph_sp.fx, ph_sp.fy, '#cfd6e0');
      insert into parent_child (parent_id, child_id) values (ph_id, a.id), (ph_id, nid);
    end if;
  end if;

  return nid;
end $$;

revoke all on function public.add_relative(text, text, text, text, text, text, text, text, jsonb) from public, anon;
grant execute on function public.add_relative(text, text, text, text, text, text, text, text, jsonb) to authenticated;
