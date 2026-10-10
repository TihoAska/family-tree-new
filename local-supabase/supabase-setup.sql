-- ============================================================
-- Supabase postavljanje za Obiteljsko stablo
-- Pokreni u Supabase: SQL Editor → New query → zalijepi → Run
-- ============================================================

-- 1) Tablica s podacima (jedan red, sve u JSON-u)
create table if not exists public.tree (
  id         int  primary key default 1,
  data       jsonb not null,
  updated_at timestamptz not null default now()
);

-- 2) Uključi Row Level Security (nitko ne čita bez pravila)
alter table public.tree enable row level security;

-- 3) Pravilo: SAMO prijavljeni korisnik smije ČITATI podatke
drop policy if exists "read_authenticated" on public.tree;
create policy "read_authenticated" on public.tree
  for select
  to authenticated
  using (true);

-- (namjerno NEMA insert/update/delete pravila za 'authenticated' ni 'anon' →
--  uređivanje ide samo iz dashboarda / service key-om)

-- 4) Ubaci podatke (zamijeni <<PASTE JSON>> sadržajem datoteke supabase-data.json)
--    Napomena: dashboard SQL editor zaobilazi RLS, pa insert radi.
insert into public.tree (id, data) values (1, $json$<<PASTE JSON>>$json$::jsonb)
on conflict (id) do update set data = excluded.data, updated_at = now();
