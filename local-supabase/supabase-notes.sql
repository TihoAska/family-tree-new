-- Bilješke o osobama (brzo dodavanje iz sidebara)
-- Pokreni u Supabase: SQL Editor → New query → zalijepi → Run

create table if not exists public.person_notes (
  id          bigint generated always as identity primary key,
  person_id   text,
  person_name text,
  note        text not null,
  user_id     uuid default auth.uid(),
  created_at  timestamptz not null default now()
);

alter table public.person_notes enable row level security;

-- prijavljeni korisnik smije samo DODAVATI (i vidjeti svoje bilješke)
drop policy if exists "notes_insert" on public.person_notes;
create policy "notes_insert" on public.person_notes
  for insert to authenticated with check (true);

drop policy if exists "notes_select_own" on public.person_notes;
create policy "notes_select_own" on public.person_notes
  for select to authenticated using (user_id = auth.uid());

-- Pregled kod kuće: Table Editor → person_notes, ili:
-- select person_name, note, created_at from public.person_notes order by created_at;
