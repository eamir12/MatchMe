-- Delta-sync support for the everyday start (FINDINGS 12.1).
--
-- A bounded delta needs a per-row change time and indexes that match the
-- predicates. chats, translations and app_config already carry updated_at;
-- matches does not. Without it a delta can see a new match but not an edit
-- (chat_start_extension_count), so extend_match_chat_window() is invisible.
--
-- Backfill uses created_at, not now(): existing matches must not look new to
-- every client's first watermark. The trigger covers all UPDATE paths,
-- including the extend_match_chat_window RPC, which does not name updated_at.
--
-- The translations trigger only fires when value changes. Seed migrations run
-- INSERT ... ON CONFLICT DO UPDATE without naming updated_at; the stamp must
-- move when content changes and must not move on a no-op upsert.
--
-- Indexes:
--   translations (locale, updated_at DESC)  - per-locale version stamp
--   chats        (user_id, updated_at)      - per-user chat delta
--   matches      (user1_id, updated_at)     - per-user match delta, side 1
--   matches      (user2_id, updated_at)     - per-user match delta, side 2
-- chat_messages already has (match_id, created_at); no new index there.
--
-- Tables are small today (matches 9 rows, chats 18, translations 15.3k), so
-- plain CREATE INDEX is used. Idempotent: safe to re-run.

alter table public.matches
  add column if not exists updated_at timestamptz;

update public.matches
set updated_at = coalesce(created_at, now())
where updated_at is null;

alter table public.matches
  alter column updated_at set default now(),
  alter column updated_at set not null;

drop trigger if exists trg_matches_set_updated_at on public.matches;
create trigger trg_matches_set_updated_at
  before update on public.matches
  for each row
  execute function public.set_row_updated_at();

drop trigger if exists trg_translations_set_updated_at on public.translations;
create trigger trg_translations_set_updated_at
  before update on public.translations
  for each row
  when (old.value is distinct from new.value)
  execute function public.set_row_updated_at();

create index if not exists idx_translations_locale_updated_at
  on public.translations (locale, updated_at desc);

create index if not exists idx_chats_user_updated_at
  on public.chats (user_id, updated_at);

create index if not exists idx_matches_user1_updated_at
  on public.matches (user1_id, updated_at);

create index if not exists idx_matches_user2_updated_at
  on public.matches (user2_id, updated_at);
