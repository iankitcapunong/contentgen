-- =============================================================================
-- AI Content Generator — initial schema
-- Run once in the Supabase SQL Editor (or `supabase db push`).
-- Safe to re-run: every statement is guarded.
-- =============================================================================

create extension if not exists "pgcrypto";

-- -----------------------------------------------------------------------------
-- 1. Status machine
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'job_status') then
    create type job_status as enum (
      'idea_ready',
      'scripting',   'script_ready',
      'voicing',     'voice_ready',
      'imaging',     'images_ready',
      'animating',   'clips_ready',
      'editing',     'render_ready',
      'uploading',   'complete',
      'failed',      'paused_for_review'
    );
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'topic_status') then
    create type topic_status as enum ('new', 'ideating', 'done', 'failed');
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 2. Tables
-- -----------------------------------------------------------------------------
create table if not exists topics (
  id           uuid primary key default gen_random_uuid(),
  raw_topic    text not null,
  source       text default 'manual',
  status       topic_status not null default 'new',
  claimed_at   timestamptz,
  attempts     int default 0,
  last_error   text,
  created_at   timestamptz default now()
);

create table if not exists jobs (
  id                 uuid primary key default gen_random_uuid(),
  topic_id           uuid references topics(id) on delete set null,

  title              text,
  hook               text,
  audience           text,

  status             job_status not null default 'idea_ready',
  status_changed_at  timestamptz default now(),
  claimed_at         timestamptz,             -- stale-claim detection
  attempts           int default 0,
  last_error         text,

  -- generation config, per job
  use_video_gen      boolean default false,   -- false = Ken Burns stills (cheap path)
  aspect             text    default '9:16',
  width              int     default 1080,
  height             int     default 1920,
  seed               bigint,                  -- locked per job for visual consistency
  style_suffix       text,                    -- appended to every image prompt

  script             jsonb,
  voice_duration_sec numeric,

  render_id          text,                    -- Shotstack render id (idempotency)
  final_video_url    text,

  drive_file_id      text,
  drive_link         text,

  cost_usd           numeric default 0,
  created_at         timestamptz default now()
);

create table if not exists scenes (
  id                  uuid primary key default gen_random_uuid(),
  job_id              uuid not null references jobs(id) on delete cascade,
  scene_number        int  not null,

  narration           text,
  image_prompt        text,
  motion_prompt       text,
  on_screen_text      text,

  audio_url           text,
  audio_duration_sec  numeric,   -- drives the whole timeline
  image_url           text,
  clip_url            text,

  provider_request_id text,      -- saved BEFORE polling, so retries resume not re-buy
  status              text default 'pending',
  last_error          text,

  created_at          timestamptz default now(),
  unique (job_id, scene_number)
);

create table if not exists job_events (
  id         bigserial primary key,
  job_id     uuid references jobs(id) on delete cascade,
  stage      text,
  level      text default 'info',
  message    text,
  payload    jsonb,
  created_at timestamptz default now()
);

create table if not exists api_usage (
  id         bigserial primary key,
  job_id     uuid references jobs(id) on delete cascade,
  provider   text,
  operation  text,
  units      numeric,
  cost_usd   numeric,
  created_at timestamptz default now()
);

create index if not exists jobs_status_idx        on jobs (status, status_changed_at);
create index if not exists jobs_claimed_idx       on jobs (claimed_at) where claimed_at is not null;
create index if not exists scenes_job_idx         on scenes (job_id, scene_number);
create index if not exists scenes_status_idx      on scenes (job_id, status);
create index if not exists topics_status_idx      on topics (status, created_at);
create index if not exists job_events_job_idx     on job_events (job_id, created_at desc);

-- -----------------------------------------------------------------------------
-- 3. Claim functions
--
--    `for update skip locked` is what makes these safe: a second worker skips a
--    locked row instead of blocking on it or double-processing it. Without this,
--    two n8n executions one minute apart will both grab the same job and you
--    will pay for every API call twice.
-- -----------------------------------------------------------------------------
create or replace function claim_topic()
returns setof topics
language plpgsql
as $fn$
begin
  return query
  update topics
     set status     = 'ideating',
         claimed_at = now(),
         attempts   = attempts + 1
   where id = (
     select id from topics
      where status = 'new'
      order by created_at
      for update skip locked
      limit 1
   )
  returning *;
end
$fn$;

create or replace function claim_job(p_target job_status, p_next job_status)
returns setof jobs
language plpgsql
as $fn$
begin
  return query
  update jobs
     set status            = p_next,
         status_changed_at = now(),
         claimed_at        = now(),
         attempts          = attempts + 1
   where id = (
     select id from jobs
      where status = p_target
      order by created_at
      for update skip locked
      limit 1
   )
  returning *;
end
$fn$;

-- -----------------------------------------------------------------------------
-- 4. Sweeper — reset jobs whose worker died mid-stage.
--    Called by workflow 99 on a schedule.
-- -----------------------------------------------------------------------------
create or replace function reset_stale_jobs(p_minutes int default 30)
returns setof jobs
language plpgsql
as $fn$
begin
  return query
  update jobs
     set status = case status
                    when 'scripting' then 'idea_ready'::job_status
                    when 'voicing'   then 'script_ready'::job_status
                    when 'imaging'   then 'voice_ready'::job_status
                    when 'animating' then 'images_ready'::job_status
                    when 'editing'   then 'clips_ready'::job_status
                    when 'uploading' then 'render_ready'::job_status
                    else status
                  end,
         status_changed_at = now(),
         claimed_at        = null,
         last_error        = 'reset by sweeper after ' || p_minutes || ' min'
   where status in ('scripting','voicing','imaging','animating','editing','uploading')
     and claimed_at < now() - (p_minutes || ' minutes')::interval
     and attempts < 4                      -- give up rather than loop forever
  returning *;
end
$fn$;

-- Jobs that exhausted their attempts get parked, not retried.
create or replace function park_exhausted_jobs()
returns setof jobs
language plpgsql
as $fn$
begin
  return query
  update jobs
     set status            = 'failed',
         status_changed_at = now(),
         last_error        = coalesce(last_error, '') || ' | exhausted attempts'
   where status in ('scripting','voicing','imaging','animating','editing','uploading')
     and claimed_at < now() - interval '30 minutes'
     and attempts >= 4
  returning *;
end
$fn$;

-- -----------------------------------------------------------------------------
-- 5. Storage buckets
--
--    PUBLIC on purpose. These hold ephemeral AI-generated intermediates that
--    third-party APIs (fal, Shotstack) must fetch by plain URL, and workflow 07
--    deletes them once the Drive upload is confirmed. Public buckets remove a
--    signed-URL round trip from every single asset handoff.
--    If you ever put client-identifiable material here, flip these to false and
--    add a signed-URL step before each external fetch.
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('audio','audio',true), ('images','images',true),
       ('clips','clips',true), ('renders','renders',true)
on conflict (id) do nothing;

-- -----------------------------------------------------------------------------
-- 6. Convenience view — what the pipeline is doing right now
--
--    security_invoker makes the view obey the RLS on jobs/scenes. Without it a
--    view runs as its owner, and the public (anon) key can read every job
--    through /rest/v1/pipeline_status even though the tables are locked.
-- -----------------------------------------------------------------------------
create or replace view pipeline_status with (security_invoker = true) as
select
  j.id, j.title, j.status, j.attempts, j.cost_usd,
  j.status_changed_at,
  count(s.id)                                             as scenes_total,
  count(s.id) filter (where s.image_url is not null)      as scenes_with_image,
  count(s.id) filter (where s.audio_url is not null)      as scenes_with_audio,
  count(s.id) filter (where s.clip_url  is not null)      as scenes_with_clip,
  round(sum(s.audio_duration_sec)::numeric, 2)            as est_duration_sec,
  j.last_error
from jobs j
left join scenes s on s.job_id = j.id
group by j.id
order by j.status_changed_at desc;

-- -----------------------------------------------------------------------------
-- 7. RLS
--
--    n8n connects with the service_role key, which bypasses RLS. We still enable
--    it so that a leaked anon key cannot read the tables.
-- -----------------------------------------------------------------------------
alter table topics     enable row level security;
alter table jobs       enable row level security;
alter table scenes     enable row level security;
alter table job_events enable row level security;
alter table api_usage  enable row level security;
-- No policies defined = anon/authenticated get nothing. service_role is unaffected.
