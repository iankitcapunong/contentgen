# AI Content Generator

`Topic → Ideation → Script → Voiceover → Images → Video → Edit → Drive → Google Sheet`

An automated short-form video pipeline. **Supabase holds the job state, n8n does the work.**
Each stage is its own small workflow that claims a job, does one thing, and advances the
status — so any stage can fail, retry, or resume without losing the stages before it.

See [PLAN.md](PLAN.md) for the reasoning behind the architecture. This file is the build guide.

---

## What's in here

```
supabase/migrations/
  0001_init.sql        schema, claim functions, storage buckets, status view
  0002_seed.sql        two sample topics (optional)

workflows/
  01-intake-ideation.json   topic  -> angles -> job rows
  02-script.json            job    -> validated scene JSON      <- the data contract
  03-voiceover.json         scenes -> ElevenLabs audio + exact durations
  04-images.json            scenes -> fal.ai FLUX stills
  05-video.json             scenes -> image-to-video clips      <- expensive, off by default
  06-render.json            scenes -> Shotstack timeline -> mp4
  07-deliver.json           mp4    -> Google Drive -> Sheet row
  99-sweeper.json           resets jobs whose worker died

docs/credentials.md    how to create each of the 7 credentials
```

---

## Build order

Deliberately **backwards**. The last mile is the cheapest thing to debug, and it proves
your Google OAuth before you have spent a cent on generation.

### Phase 0 — Database

1. Create a Supabase project.
2. SQL Editor → paste `supabase/migrations/0001_init.sql` → Run.
3. Verify: `select * from pipeline_status;` returns an empty table, not an error.
4. Confirm four buckets exist under **Storage**: `audio`, `images`, `clips`, `renders`.

### Phase 1 — Prove delivery (workflow 07)

1. Create the `Supabase service_role`, `Google Drive` and `Google Sheets` credentials
   ([docs/credentials.md](docs/credentials.md)).
2. Make a Drive folder for output; its ID is the last URL segment. Put that in 07's Config.
3. Make a Google Sheet with a tab named `Videos` and this **exact** header row:

   ```
   Date | Job ID | Title | Hook | Duration | Drive Link | Folder Link | Thumbnail | Scene Count | Cost USD | Status | Posted?
   ```

   The Sheets node auto-maps by header name — a renamed header silently drops that column.
4. Import `07-deliver.json`, fix the credential dropdowns, fill Config.
5. Insert a fake finished job pointing at any public mp4:

   ```sql
   insert into jobs (title, hook, status, final_video_url)
   values ('Delivery test', 'testing', 'render_ready',
           'https://download.samplelib.com/mp4/sample-5s.mp4');
   ```
6. Execute the workflow manually. You should get a dated Drive folder, an mp4 inside it,
   and a new Sheet row. **Do not continue until this works.**

### Phase 2 — Topic to script (workflows 01, 02)

1. Add the `OpenRouter` credential. Import both workflows, fill Config.
2. `insert into topics (raw_topic) values ('Why most people quit the gym in February');`
3. Run 01, then 02. Check:

   ```sql
   select scene_number, narration, image_prompt from scenes order by scene_number;
   ```

   Narration should be 12–20 words per scene, and every `image_prompt` should end with the
   same style suffix. If jobs keep bouncing back to `idea_ready`, read `jobs.last_error` —
   the validator says exactly which scene failed and why.

### Phase 3 — Voice and images (workflows 03, 04)

1. Add `ElevenLabs` and `fal.ai` credentials. Fill in your `voice_id`.
2. Run them. Verify every scene has `audio_url`, `audio_duration_sec` and `image_url`:

   ```sql
   select * from pipeline_status;
   ```
3. Open one audio file and one image from Storage and check they are real.

### Phase 4 — Render (workflow 06) ⭐

With `use_video_gen = false`, workflow 04 sends jobs straight to `clips_ready`, so 06 picks
them up and builds a Ken Burns video from the stills.

1. Add the `Shotstack` credential, set `shotstack_env` to `stage`.
2. Run 06, then 07.

**This is the milestone.** A complete pipeline — topic in, finished video in Drive and a row
in your Sheet — at roughly **$0.40 per video**. Activate all seven workflows and it runs
unattended. Most content formats never need more than this.

### Phase 5 — Video generation (workflow 05), optional

Only when the stills path is boring and reliable.

1. Import `05-video.json`, add Config values, activate it.
2. Turn it on for **one** job first:

   ```sql
   update jobs set use_video_gen = true where id = '...';
   ```
3. Watch the cost. This step is 90%+ of the unit price — roughly $3–26 per video versus
   $0.40. Set `angles_per_topic` back to 1 while you evaluate.

### Phase 6 — Let it run

Activate `99-sweeper.json`. Feed topics in by inserting rows into `topics` (by hand, from a
Sheet, from an RSS trigger — anything that can write a row).

---

## Operating it

```sql
-- what is happening right now
select * from pipeline_status;

-- why did something fail
select id, title, status, attempts, last_error from jobs where status = 'failed';

-- replay a job from any stage
update jobs set status = 'script_ready', attempts = 0, claimed_at = null where id = '...';

-- retry one bad scene after editing its prompt by hand
update scenes set image_url = null where job_id = '...' and scene_number = 4;
update jobs   set status = 'voice_ready', attempts = 0 where id = '...';
```

Because each stage skips work that is already done, that last pattern regenerates **only**
scene 4 and leaves the rest alone.

## Cost controls already wired in

| Guard | Where | What it stops |
|---|---|---|
| `use_video_gen` default false | 01 Config → jobs | The 10x cost stage, until you opt in |
| "Needs an image/clip?" | 04, 05 | Retries re-buying generations you already paid for |
| `provider_request_id` saved pre-poll | 05, 06 | A dead execution paying twice for the same clip |
| `max_scenes` | 05 | A runaway 40-scene script becoming a real bill |
| Max 20 scenes | 02 validator | The same thing, one stage earlier |
| `attempts` ceiling + sweeper | all | A poisoned job cycling forever |

---

## Known limits and what is unverified

Honest status of what is in this repo:

- **The workflow JSON is structurally validated** — valid JSON, no broken connections, no
  dangling `$('Node')` references, no unreachable nodes. That is a structural check only.
- **Nothing here has been run against the live APIs.** Request and response shapes follow
  each provider's documented behaviour, but verify them on your first manual run —
  particularly ElevenLabs' `character_end_times_seconds` field (workflow 03) and fal's
  `status_url` / `response_url` (workflow 05). If a provider has changed a field name, the
  Code node will throw with a clear message rather than corrupt data.
- **The SQL has not been executed** against a live Postgres — there was no database
  available in the environment where it was written. Run `0001_init.sql` first and read the
  output before importing anything.
- **`n8n-nodes-base` type versions** are pinned to current-generation values. On an older
  n8n, imports may warn about a version mismatch; n8n usually migrates them automatically.
- Storage buckets are **public** by design (see the comment in `0001_init.sql`). Fine for
  ephemeral AI-generated media; change it before putting anything client-identifiable there.
- **Workflow 07 can create a duplicate Drive file** if the Sheets append fails and the job
  retries after the upload succeeded. Rare, and visible in the dated folder.
