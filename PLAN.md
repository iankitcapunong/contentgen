# AI Content Generator — n8n + Supabase Build Plan

Pipeline from the whiteboard:
`Topic → Ideation → Script → Voice over → Image generator → Video generator → Edit → Upload to Drive → Populate Google Sheet`

**Verdict: yes, buildable — with one hard exception.** n8n cannot render or edit video. Every
other stage is a native node or a plain HTTP call. The edit step needs either a cloud render API
(Creatomate / Shotstack / JSON2Video) or a self-hosted n8n container with ffmpeg baked in. That
single decision shapes the whole build, so it gets decided first (§3).

---

## 1. Stage-by-stage analysis

| # | Stage | How it's actually done | Difficulty |
|---|-------|------------------------|-----------|
| 1 | Topic | n8n Form Trigger / Sheet row / RSS / Schedule. Row into `topics`. | Trivial |
| 2 | Ideation | LLM node + Structured Output Parser → N angles per topic. | Trivial |
| 3 | Script | LLM with a **strict scene-array JSON schema**. Everything downstream reads this shape. | Easy, high-leverage |
| 4 | Voice over | ElevenLabs via HTTP Request. Use the `with-timestamps` endpoint — it returns the duration you need for sync. | Easy |
| 5 | Image gen | fal.ai FLUX (or gpt-image / Ideogram). Sync for fast models, queue API for slow. | Easy |
| 6 | Video gen | Image→video (Kling / Veo / Seedance / Luma via fal, or Higgsfield). **Async: submit → poll → download.** Fixed clip lengths. Most expensive stage by 10x. | Medium |
| 7 | Edit | **n8n cannot do this.** External render service or self-hosted ffmpeg. | Hard — the real work |
| 8 | Upload to Drive | Native Google Drive node, OAuth2. Folder per video, return `webViewLink`. | Trivial |
| 9 | Populate Sheet | Native Google Sheets node, append row. | Trivial |

**Note:** Supabase Edge Functions run on Deno and cannot execute ffmpeg binaries. Don't plan the
edit step there.

---

## 2. Architecture: Supabase as state machine, n8n as stage workers

Do **not** build this as one long workflow. Reasons:

- A full run takes 10–40 minutes (video gen and render dominate). n8n execution timeouts will kill it.
- A failure at minute 30 throws away every paid API call before it.
- Retrying a monolith re-bills the expensive stages.

Instead: **Supabase holds job state; each pipeline stage is its own small n8n workflow** that claims
rows in a given status, does one thing, writes the result, and advances the status. A 1-minute
Schedule trigger drives each worker.

```
              ┌─────────────── Supabase (Postgres + Storage) ───────────────┐
              │  jobs.status drives everything; assets live in Storage      │
              └─────────────────────────────────────────────────────────────┘
                    ▲         ▲         ▲         ▲         ▲         ▲
 W1 Intake ──▶ W2 Script ──▶ W3 Voice ──▶ W4 Images ──▶ W5 Video ──▶ W6 Render ──▶ W7 Deliver
 (form/sheet)   (LLM JSON)   (11Labs)     (fal FLUX)    (fal i2v)   (Creatomate)  (Drive+Sheet)
```

Benefits: resume from any stage, per-stage retry, per-stage cost cap, a human review gate anywhere
you want one (just add a `paused_for_review` status), and full observability from one table.

---

## 3. The edit step — pick one (decide before building)

| Option | Cost | Effort | Trade-off |
|--------|------|--------|-----------|
| **A. Creatomate** (recommended start) | ~$41/mo entry tier | Low — build a template in their editor, send JSON modifications | Fastest path. Auto-fits element duration to audio, which solves sync for free. |
| **B. Shotstack** | Pay-per-render | Low-medium | JSON timeline, no visual template needed. Good API. |
| **C. Self-hosted n8n + ffmpeg** | $0 (VPS ~$12/mo) | High | Full control, no per-render fee. Requires a **custom Docker image** — the official n8n image ships without ffmpeg — plus the Execute Command node (unavailable on n8n Cloud) and enough CPU/RAM. |

**Recommendation:** start with A, migrate to C once volume makes the subscription the bigger line item.

---

## 4. Supabase schema

```sql
-- status machine
create type job_status as enum (
  'topic_new','ideating','idea_ready','scripting','script_ready',
  'voicing','voice_ready','imaging','images_ready',
  'animating','clips_ready','editing','render_ready',
  'uploading','complete','failed','paused_for_review'
);

create table topics (
  id uuid primary key default gen_random_uuid(),
  raw_topic text not null,
  source text default 'manual',
  created_at timestamptz default now()
);

create table jobs (
  id uuid primary key default gen_random_uuid(),
  topic_id uuid references topics(id),
  title text,
  hook text,
  status job_status not null default 'topic_new',
  status_changed_at timestamptz default now(),
  attempts int default 0,
  last_error text,
  claimed_at timestamptz,          -- stale-claim detection
  script jsonb,                    -- full LLM script output
  voice_url text,
  voice_duration_sec numeric,
  final_video_url text,            -- render service output
  drive_file_id text,
  drive_link text,
  sheet_row int,
  cost_usd numeric default 0,
  created_at timestamptz default now()
);

create table scenes (
  id uuid primary key default gen_random_uuid(),
  job_id uuid references jobs(id) on delete cascade,
  scene_number int not null,
  narration text,
  image_prompt text,
  motion_prompt text,
  on_screen_text text,
  audio_url text,
  audio_duration_sec numeric,      -- drives the timeline
  image_url text,
  clip_url text,
  provider_request_id text,        -- async polling + idempotency
  status text default 'pending',
  unique (job_id, scene_number)
);

create table job_events (
  id bigserial primary key,
  job_id uuid references jobs(id) on delete cascade,
  stage text, level text, message text, payload jsonb,
  created_at timestamptz default now()
);

create table api_usage (
  id bigserial primary key,
  job_id uuid references jobs(id) on delete cascade,
  provider text, operation text, units numeric, cost_usd numeric,
  created_at timestamptz default now()
);

create index on jobs (status, status_changed_at);
create index on scenes (job_id, status);
```

**Concurrency-safe claim** — prevents two workers grabbing the same job. Call from n8n via
`POST /rest/v1/rpc/claim_job` with the service role key:

```sql
create or replace function claim_job(target job_status, next_status job_status)
returns setof jobs
language plpgsql
as $func$
begin
  return query
  update jobs
     set status = next_status,
         status_changed_at = now(),
         claimed_at = now(),
         attempts = attempts + 1
   where id = (
     select id from jobs
      where status = target
      order by created_at
      for update skip locked
      limit 1
   )
  returning *;
end
$func$;
```

`for update skip locked` is what makes this safe — a second worker skips the locked row instead of
blocking on it or double-processing.

**Storage buckets:** `audio/`, `images/`, `clips/`, `renders/` — private, exposed to third-party
APIs via signed URLs. Supabase free tier is ~1GB; video will exhaust it fast. Budget for Pro
($25/mo) **and** delete `clips/` + `renders/` once the Drive upload confirms.

---

## 5. Workflow-by-workflow node breakdown

### W1 — Intake & Ideation
`Schedule/Form Trigger` → `HTTP: rpc/claim_job('topic_new','ideating')` → `IF no rows → stop`
→ `LLM Chain` (+ Structured Output Parser: `{angles: [{title, hook, audience}]}`)
→ `Supabase: insert jobs` → `status = idea_ready`

### W2 — Script
`Schedule` → `claim_job('idea_ready','scripting')` → `LLM Chain` with the scene schema below
→ `Split Out` scenes → `Supabase: insert scenes` → `status = script_ready`

**Scene schema — the contract for the whole pipeline:**
```json
{
  "title": "string",
  "total_duration_target_sec": 60,
  "scenes": [{
    "scene_number": 1,
    "narration": "12-20 words — one breath, 5-8 seconds spoken",
    "image_prompt": "full visual description, no camera-motion words",
    "motion_prompt": "camera/subject motion only, for the i2v model",
    "on_screen_text": "6 words max"
  }]
}
```
Enforce the 12–20 word narration rule **in the prompt** — §7.2 explains why it matters.

**Model selection (OpenRouter).** Split the two LLM stages by stakes:

- *W1 ideation* — cheap, fast model. Low risk, and you generate several throwaway angles per topic.
- *W2 script* — frontier model. Six downstream workflows key off this JSON, and strict-schema
  support varies widely across OpenRouter's catalog. Cheap open-weight models tend to emit
  *approximately* correct JSON, which fails silently downstream instead of failing loudly here.

Either way, **validate before inserting**: a Code node checks that every scene has a
`scene_number`, non-empty `narration`, and `image_prompt`, and that narration is 12–20 words.
On failure, retry the LLM call rather than writing a malformed row — a bad script row poisons
every stage after it.

### W3 — Voiceover
`Schedule` → `claim_job('script_ready','voicing')` → `Supabase: get scenes` → `Loop Over Items`
→ `HTTP POST api.elevenlabs.io/v1/text-to-speech/{voice_id}/with-timestamps`
→ `Code`: base64 → binary; duration = last value in `character_end_times_seconds`
→ `Supabase Storage: upload` → `update scenes.audio_url, audio_duration_sec` → `status = voice_ready`

### W4 — Images
`claim_job('voice_ready','imaging')` → `Loop scenes` → `HTTP POST fal.run/fal-ai/flux/dev`
→ `HTTP GET` the returned image → `Storage upload` (fal URLs expire — always re-host)
→ `update scenes.image_url` → `status = images_ready`

### W5 — Video (skippable — see §7.1)
`claim_job('images_ready','animating')` → `Loop scenes` → `HTTP POST queue.fal.run/...` (submit)
→ save `provider_request_id` **before polling** → `Wait 30s` → `HTTP GET .../status`
→ `IF not done → loop back (max 20 attempts)` → `GET response_url` → download → Storage
→ `scenes.clip_url` → `status = clips_ready`

### W6 — Render
`claim_job('clips_ready','editing')` → `Code`: build the modifications payload from scenes, each
element's duration = that scene's `audio_duration_sec` → `HTTP POST Creatomate /v1/renders`
→ `Wait` → poll until `succeeded` → `jobs.final_video_url` → `status = render_ready`

### W7 — Deliver
`claim_job('render_ready','uploading')` → `HTTP GET` final mp4 → `Google Drive: create folder`
(`YYYY-MM-DD — {title}`) → `Google Drive: upload` → `Google Drive: share` →
`Google Sheets: append row` → `status = complete` → `Storage: delete clips/ + renders/`

**Sheet columns:** `Date | Job ID | Topic | Title | Hook | Duration | Drive Link | Thumbnail | Scene Count | Cost USD | Status | Posted?`

---

## 6. What you need to provision

### Accounts & keys
| Service | Purpose | Notes |
|---------|---------|-------|
| n8n | Orchestration | Self-hosted Docker recommended (Execute Command + no execution caps) |
| Supabase | Postgres + Storage | Pro tier ~$25/mo once video assets land |
| **OpenRouter** (or OpenAI / Anthropic direct) | Ideation + script | One key, any model. Lets you run a cheap model for ideation and a frontier model for the script — see §5 W2 note |
| ElevenLabs | Voiceover | Needs the `with-timestamps` endpoint |
| fal.ai | Images **and** video | One key covers FLUX + Kling/Veo/Seedance |
| Creatomate *or* Shotstack | Render | Skip if going self-hosted ffmpeg |
| Google Cloud project | Drive + Sheets | OAuth2 client, scopes `drive.file` + `spreadsheets` |

### n8n credentials to create
`Supabase` (URL + service_role key) · `OpenRouter` (native node, or the OpenAI credential with base URL
`https://openrouter.ai/api/v1`) · `Google Drive OAuth2` ·
`Google Sheets OAuth2` · plus Header Auth credentials for ElevenLabs (`xi-api-key`),
fal (`Authorization: Key <FAL_KEY>`), Creatomate (`Bearer <key>`).

### Self-hosted env (if applicable)
```
N8N_DEFAULT_BINARY_DATA_MODE=filesystem   # keeps mp4s out of RAM
EXECUTIONS_TIMEOUT=3600
EXECUTIONS_DATA_PRUNE=true
N8N_ENCRYPTION_KEY=<generate once, back it up>
```

### Cost per 60s video — *estimates, verify current pricing*
| Stage | Budget path | Premium path |
|-------|------------|--------------|
| LLM (ideation + script) | $0.02 | $0.10 |
| Voiceover (~900 chars) | $0.10 | $0.25 |
| Images (8 × FLUX) | $0.03 (schnell) | $0.20 (dev) |
| **Video (8 × 8s clips)** | **$3.20** | **$25.00** |
| Render | $0.05 | $0.20 |
| **Total** | **≈ $3.40** | **≈ $25.75** |

Video generation is **90%+ of unit cost**. See §7.1.

---

## 7. The things that will break — and the fix

**7.1 Cost runaway.** At ~$3–26 per video, a bug that retries W5 in a loop is a real bill.
→ Build the **entire pipeline without W5 first**: pass still images to the render step with
Ken Burns pan/zoom. That's ~$0.40/video, ships in a fraction of the time, and for many content
formats is indistinguishable to the viewer. Add W5 later behind a per-job boolean flag. Also:
store `provider_request_id` before polling so a retry resumes the existing job instead of buying a
new one, and check a hard `cost_usd` ceiling before every paid call.

**7.2 Audio/video desync — the #1 failure of these pipelines.** Never guess durations.
→ Drive every timeline element from `scenes.audio_duration_sec`, taken from the ElevenLabs
timestamps response. Video models emit **fixed** lengths (5s/8s/10s) — you cannot request 6.4s. So
constrain narration to 12–20 words (≈5–8s at natural pace) at the *script* stage, then pad or trim
the clip to the audio, never the reverse.

**7.3 Visual inconsistency between scenes.** Scene 3 looks like a different show than scene 1.
→ Lock a `seed` per job, append an identical style suffix to every `image_prompt`, and pass
scene 1's output as a reference image where the model supports it.

**7.4 Async polling.** Video gen takes 1–6 minutes per clip; renders 1–10 minutes.
→ Wait node + bounded retry (max 20 × 30s), plus a separate sweeper workflow that resets jobs whose
`claimed_at` is older than 30 minutes back to the previous status.

**7.5 n8n memory on large binaries.** A 200MB mp4 through n8n Cloud will OOM.
→ Move **URLs**, not bytes. Let the render service fetch from Supabase signed URLs. Only W7 handles
real bytes, and only once. Set `filesystem` binary mode on self-hosted.

**7.6 Content-policy rejections.** Image/video APIs refuse prompts unpredictably.
→ Catch the error, route to `paused_for_review`, don't fail the whole job. One bad scene shouldn't
kill nine good ones.

**7.7 Google OAuth.** Refresh tokens expire on unverified apps (7 days in testing mode).
→ Publish the Google Cloud consent screen, or use a service account with domain-wide delegation.

---

## 8. Build order

| Phase | Deliverable | Why this order |
|-------|-------------|----------------|
| **0** | Supabase schema + buckets + `claim_job` RPC; one job row inserted by hand | Foundation |
| **1** | **W7 first** — dummy mp4 → Drive → Sheet row | Last mile is cheapest to debug; proves OAuth early |
| **2** | W1 + W2 — topic → validated scene JSON | Locks the data contract |
| **3** | W3 + W4 — voice + images, with real durations | Cheap, fast, fully testable |
| **4** | W6 with **stills only** (Ken Burns) | **End-to-end working product at ~$0.40/video** |
| **5** | W5 video gen behind a per-job flag | Upgrade, not a dependency |
| **6** | Hardening — retry sweeper, cost caps, review gate, `api_usage` tracking | Production |

Phase 4 is the milestone that matters: a complete, shipping content machine before a dollar goes to
video generation.

---

## 9. Open decisions

1. **Render engine** — Creatomate (fast, ~$41/mo) vs self-hosted ffmpeg (free, custom Docker)?
2. **n8n hosting** — Cloud (no Execute Command, execution caps) vs self-hosted VPS?
3. **Format** — 9:16 shorts or 16:9 long-form? Changes the render template and the scene count.
4. **Review gate** — fully automatic, or human approval after the script stage?
5. **Voice** — one fixed ElevenLabs voice, or per-topic selection?
