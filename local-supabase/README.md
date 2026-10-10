# Lokalni Supabase (Docker)

Lokalna kopija baze za rad bez interneta: tablice `tree` i `person_notes`, prijava (Auth) i Studio.
Portovi su 55xxx, da se ne sudara s drugim Supabase projektima.

    cd local-supabase
    npx supabase start      # pokretanje (podaci ostaju u Docker volumenu)
    npx supabase stop       # zaustavljanje (podaci ostaju)
    npx supabase status     # adrese i ključevi

- API: http://127.0.0.1:55321, Studio: http://127.0.0.1:55323
- Stranica: iz korijena repoa `npx live-server --port=3000 --open=index.html`
  (na localhostu koristi LOKALNI Supabase; `?cloud` u adresi prisiljava oblak, GitHub Pages uvijek koristi oblak)
- `supabase/seed.sql` sadrži podatke stabla i NIJE u gitu (osobni podaci). Bez njega baza ima samo prazne tablice.
- Lokalni korisnik se pravi preko Auth admin API-ja ili Studija (Authentication, Users).
