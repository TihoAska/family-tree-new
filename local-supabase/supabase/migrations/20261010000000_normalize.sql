-- Prelazak s jednog JSON-a (tablica tree) na normalizirane tablice.
-- Tablica `tree` ostaje netaknuta (sigurnosna kopija) dok se sve ne potvrdi.

-- ---------- pomoćno: je li korisnik admin (app_metadata.admin u JWT-u) ----------
create or replace function public.is_admin() returns boolean
language sql stable as $$
  select coalesce((auth.jwt() -> 'app_metadata' ->> 'admin')::boolean, false)
$$;

-- ---------- tablice ----------
create table if not exists public.persons (
  id         text primary key default gen_random_uuid()::text,
  name       text not null,
  born       text,
  died       text,
  info       text,
  x          real,
  y          real,
  age_anchor boolean not null default false,   -- polazne osobe za izračun starosti (veličina planeta)
  is_eldest  boolean not null default false,   -- najstariji poznati predak svake strane (svijetli na grafu)
  color      text check (color ~ '^#[0-9a-fA-F]{6}$'),   -- spremljena boja planeta (braća i sestre imaju istu)
  updated_at timestamptz not null default now(),
  updated_by uuid,
  deleted_at timestamptz,                      -- meko brisanje: null = aktivna osoba
  deleted_by uuid
);

create table if not exists public.marriages (
  id       bigint generated always as identity primary key,
  person_a text not null references public.persons(id) on update cascade on delete cascade,
  person_b text not null references public.persons(id) on update cascade on delete cascade,
  check (person_a <> person_b)
);
create unique index if not exists marriages_par_uq
  on public.marriages (least(person_a, person_b), greatest(person_a, person_b));
create index if not exists marriages_b_idx on public.marriages (person_b);

create table if not exists public.parent_child (
  ord       bigint generated always as identity,
  parent_id text not null references public.persons(id) on update cascade on delete cascade,
  child_id  text not null references public.persons(id) on update cascade on delete cascade,
  primary key (parent_id, child_id),
  check (parent_id <> child_id)
);
create index if not exists parent_child_child_idx on public.parent_child (child_id);

create table if not exists public.person_history (
  id         bigint generated always as identity primary key,
  person_id  text not null,
  field      text not null,
  old_value  text,
  new_value  text,
  changed_by uuid,
  changed_at timestamptz not null default now()
);
create index if not exists person_history_person_idx on public.person_history (person_id, changed_at desc);

-- ---------- povijest izmjena (trigger) ----------
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
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;

drop trigger if exists persons_audit_trg on public.persons;
create trigger persons_audit_trg before update on public.persons
  for each row execute function public.persons_audit();

-- ---------- RLS ----------
alter table public.persons        enable row level security;
alter table public.marriages      enable row level security;
alter table public.parent_child   enable row level security;
alter table public.person_history enable row level security;

do $$
declare t text;
begin
  foreach t in array array['persons','marriages','parent_child'] loop
    execute format('drop policy if exists %I on public.%I', t||'_read',  t);
    execute format('drop policy if exists %I on public.%I', t||'_write', t);
    execute format('create policy %I on public.%I for select to authenticated using (true)', t||'_read', t);
    execute format('create policy %I on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t||'_write', t);
  end loop;
end $$;

-- obrisane (meko) osobe vidi samo admin, i preko API-ja
drop policy if exists persons_read on public.persons;
create policy persons_read on public.persons for select to authenticated using (deleted_at is null or public.is_admin());

drop policy if exists person_history_read on public.person_history;
create policy person_history_read on public.person_history for select to authenticated using (public.is_admin());

-- ---------- get_tree(): isti JSON oblik kao stara tablica tree, da se frontend ne mora prepisivati ----------
create or replace function public.get_tree() returns jsonb
language sql stable as $$
  with p as (select * from public.persons where deleted_at is null)
  select jsonb_build_object(
    'persons', coalesce((select jsonb_object_agg(id, jsonb_strip_nulls(jsonb_build_object('n', name, 'born', born, 'died', died, 'info', info, 'anchor', case when age_anchor then true end, 'eldest', case when is_eldest then true end, 'color', color))) from p), '{}'::jsonb),
    'marriages', coalesce((select jsonb_agg(jsonb_build_array(m.person_a, m.person_b) order by m.id) from public.marriages m where m.person_a in (select id from p) and m.person_b in (select id from p)), '[]'::jsonb),
    'parents',   coalesce((select jsonb_agg(jsonb_build_array(c.parent_id, c.child_id) order by c.ord) from public.parent_child c where c.parent_id in (select id from p) and c.child_id in (select id from p)), '[]'::jsonb),
    'positions', coalesce((select jsonb_object_agg(id, jsonb_build_object('x', x, 'y', y)) from p where x is not null and y is not null), '{}'::jsonb)
  )
$$;
grant execute on function public.get_tree() to authenticated;

-- ---------- dodavanje osobe iz aplikacije: add_relative() ----------
-- Jednim pozivom (u jednoj transakciji) stvara novu osobu i vezu prema odabranoj osobi.
-- relation: 'spouse' | 'child' | 'parent' | 'sibling'. Samo admin. Boju bira korisnik (p_color, npr. '#f4dc86');
-- ako nije zadana, uzima se boja odabrane osobe. Položaj se bira automatski (slobodno mjesto uz osobu),
-- a već postojeće osobe se NE diraju.

-- slobodno mjesto uz osobu (nova osoba ne smije prekriti postojeće)
create or replace function public.free_spot(ax real, ay real, base double precision, out fx real, out fy real)
language plpgsql stable as $$
declare d int; i int; off double precision; ang double precision; cx double precision; cy double precision;
begin
  foreach d in array array[85, 115, 150, 200] loop
    for i in 0..24 loop
      off := case when i = 0 then 0 else ((i + 1) / 2) * (pi() / 12) * (case when i % 2 = 1 then 1 else -1 end) end;
      ang := base + off;
      cx := ax + d * cos(ang); cy := ay + d * sin(ang);
      if not exists (select 1 from public.persons p where p.x is not null and p.deleted_at is null and (p.x - cx)^2 + (p.y - cy)^2 < 3025) then
        fx := round(cx); fy := round(cy); return;
      end if;
    end loop;
  end loop;
  fx := round(ax + 250 * cos(base)); fy := round(ay + 250 * sin(base));
end $$;

create or replace function public.add_relative(
  p_anchor text, p_relation text, p_name text,
  p_born text default null, p_died text default null, p_info text default null,
  p_other_parent text default null, p_color text default null
) returns text
language plpgsql set search_path = public as $$
declare
  a persons%rowtype; o persons%rowtype;
  nid text := gen_random_uuid()::text;
  nm text := nullif(btrim(p_name), '');
  col text; nparents int; ph_id text;
  outward double precision; base double precision;
  sp record; ph_sp record;
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
    insert into persons (id, name, born, died, info, x, y, color)
      values (nid, nm, nullif(btrim(p_born),''), nullif(btrim(p_died),''), nullif(btrim(p_info),''), sp.fx, sp.fy, col);
    insert into marriages (person_a, person_b) values (a.id, nid);

  elsif p_relation = 'child' then
    if p_other_parent is not null then
      select * into o from persons where id = p_other_parent and deleted_at is null;
      if not found then raise exception 'Drugi roditelj nije pronađen.'; end if;
      if o.id = a.id then raise exception 'Drugi roditelj mora biti druga osoba.'; end if;
    end if;
    base := outward;
    select * into sp from public.free_spot(a.x, a.y, base);
    insert into persons (id, name, born, died, info, x, y, color)
      values (nid, nm, nullif(btrim(p_born),''), nullif(btrim(p_died),''), nullif(btrim(p_info),''), sp.fx, sp.fy, col);
    insert into parent_child (parent_id, child_id) values (a.id, nid);
    if o.id is not null then insert into parent_child (parent_id, child_id) values (o.id, nid); end if;

  elsif p_relation = 'parent' then
    select count(*) into nparents from parent_child pc join persons q on q.id = pc.parent_id and q.deleted_at is null where pc.child_id = a.id;
    if nparents >= 2 then raise exception 'Osoba već ima dva roditelja.'; end if;
    base := outward + pi();
    select * into sp from public.free_spot(a.x, a.y, base);
    insert into persons (id, name, born, died, info, x, y, color)
      values (nid, nm, nullif(btrim(p_born),''), nullif(btrim(p_died),''), nullif(btrim(p_info),''), sp.fx, sp.fy, col);
    insert into parent_child (parent_id, child_id) values (nid, a.id);

  else  -- sibling
    base := outward + pi() / 2;
    select * into sp from public.free_spot(a.x, a.y, base);
    insert into persons (id, name, born, died, info, x, y, color)
      values (nid, nm, nullif(btrim(p_born),''), nullif(btrim(p_died),''), nullif(btrim(p_info),''), sp.fx, sp.fy, col);
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

revoke all on function public.add_relative(text, text, text, text, text, text, text, text) from public, anon;
grant execute on function public.add_relative(text, text, text, text, text, text, text, text) to authenticated;

-- ---------- meko brisanje i vraćanje osobe (samo admin) ----------
-- Osoba se samo označi kao obrisana (red i veze ostaju u bazi), pa se može vratiti.
create or replace function public.delete_person(p_id text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Samo admin može brisati osobe.'; end if;
  update persons set deleted_at = now(), deleted_by = auth.uid() where id = p_id and deleted_at is null;
  if not found then raise exception 'Osoba nije pronađena ili je već obrisana.'; end if;
  insert into person_history(person_id, field, old_value, new_value, changed_by) values (p_id, 'deleted', null, 'obrisana', auth.uid());
end $$;

create or replace function public.restore_person(p_id text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Samo admin može vraćati osobe.'; end if;
  update persons set deleted_at = null, deleted_by = null where id = p_id and deleted_at is not null;
  if not found then raise exception 'Osoba nije pronađena ili nije obrisana.'; end if;
  insert into person_history(person_id, field, old_value, new_value, changed_by) values (p_id, 'deleted', 'obrisana', null, auth.uid());
end $$;

revoke all on function public.delete_person(text), public.restore_person(text) from public, anon;
grant execute on function public.delete_person(text), public.restore_person(text) to authenticated;

-- ---------- uvoz iz stare tablice tree: svaka osoba dobiva novi UUID, veze i pozicije se prevode ----------
-- Bez force=true ne radi ništa ako persons već ima podataka (da se uređivanja ne prepišu slučajno).
create or replace function public.import_tree_json(force boolean default false) returns text
language plpgsql security definer set search_path = public as $$
declare d jsonb;
begin
  select data into d from public.tree where id = 1;
  if d is null then return 'nema podataka u tablici tree'; end if;
  if not force and exists (select 1 from public.persons) then
    return 'preskočeno: persons već ima podataka';
  end if;

  delete from public.parent_child;
  delete from public.marriages;
  delete from public.persons;

  drop table if exists _idmap;
  create temp table _idmap on commit drop as
    select k as old_id, gen_random_uuid()::text as new_id from jsonb_object_keys(d->'persons') k;

  insert into public.persons (id, name, born, died, info, age_anchor, is_eldest)
    select m.new_id, e.v->>'n', e.v->>'born', e.v->>'died', e.v->>'info',
           m.old_id in ('baka_ivka', 'dida_jure'),
           m.old_id in ('pile_d', 'marko_st')
    from jsonb_each(d->'persons') e(k, v) join _idmap m on m.old_id = e.k;

  update public.persons p set x = (pos.v->>'x')::real, y = (pos.v->>'y')::real
    from jsonb_each(coalesce(d->'positions','{}'::jsonb)) pos(k, v)
    join _idmap m on m.old_id = pos.k
    where p.id = m.new_id;

  insert into public.marriages (person_a, person_b)
    select ma.new_id, mb.new_id
    from jsonb_array_elements(d->'marriages') with ordinality t(a, n)
    join _idmap ma on ma.old_id = t.a->>0
    join _idmap mb on mb.old_id = t.a->>1
    order by t.n
    on conflict do nothing;

  insert into public.parent_child (parent_id, child_id)
    select mp.new_id, mc.new_id
    from jsonb_array_elements(d->'parents') with ordinality t(a, n)
    join _idmap mp on mp.old_id = t.a->>0
    join _idmap mc on mc.old_id = t.a->>1
    order by t.n
    on conflict do nothing;

  return 'uvezeno: ' || (select count(*) from public.persons) || ' osoba, '
      || (select count(*) from public.marriages) || ' brakova, '
      || (select count(*) from public.parent_child) || ' veza roditelj-dijete';
end $$;
revoke all on function public.import_tree_json(boolean) from public, anon, authenticated;

select public.import_tree_json();
