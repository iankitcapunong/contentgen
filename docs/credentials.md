# Credentials

Seven credentials. Create each one in n8n under **Credentials → New**, using the exact
name in the first column — the workflow files reference these names.

> **After importing a workflow, n8n will show a red "credential not set" warning on
> each HTTP node.** That is expected: the placeholder IDs in the JSON (`SUPABASE_CRED`
> etc.) do not match the IDs n8n generates on your instance. Open each flagged node and
> pick the credential from the dropdown once. n8n remembers it from then on.

---

## 1. `Supabase service_role` — type: **Custom Auth**

Supabase needs two headers, which the plain Header Auth credential cannot do.

Credential type: **Custom Auth**. Paste into the JSON field:

```json
{
  "headers": {
    "apikey": "YOUR_SERVICE_ROLE_KEY",
    "Authorization": "Bearer YOUR_SERVICE_ROLE_KEY",
    "Content-Type": "application/json"
  }
}
```

Get the key at **Supabase → Project Settings → API → service_role**.

⚠️ `service_role` bypasses Row Level Security entirely. It belongs only in n8n, never in
a browser, a client app, or a committed file.

---

## 2. `OpenRouter` — type: **Header Auth**

| Field | Value |
|---|---|
| Name | `Authorization` |
| Value | `Bearer sk-or-v1-...` |

Key from <https://openrouter.ai/keys>. Set a spend limit on the key while you build.

---

## 3. `ElevenLabs` — type: **Header Auth**

| Field | Value |
|---|---|
| Name | `xi-api-key` |
| Value | your API key (no prefix) |

Key from ElevenLabs → Profile → API Key.

You also need a **voice ID**: open any voice in the Voice Library, and the ID is the
last segment of the URL. That goes in workflow 03's Config node, not here.

---

## 4. `kie.ai` — type: **Header Auth**

| Field | Value |
|---|---|
| Name | `Authorization` |
| Value | `Bearer YOUR_KIE_KEY` |

Note the word `Bearer` and one space before the key. Key from <https://kie.ai/api-key>.

One credential serves both workflow 04 (images) and 05 (video). kie.ai bills from a
prepaid credit balance, so top it up before the first run — an empty balance shows up in
`jobs.last_error` as `kie.ai rejected the image task (402)`.

---

## 5. `Shotstack` — type: **Header Auth**

| Field | Value |
|---|---|
| Name | `x-api-key` |
| Value | your Shotstack key |

Shotstack issues **separate keys for stage and production**. The one you paste must
match the `shotstack_env` value in workflow 06's Config node, or every render 401s.

---

## 6. `Google Drive` — type: **Google Drive OAuth2 API**
## 7. `Google Sheets` — type: **Google Sheets OAuth2 API**

Both come from one Google Cloud project:

1. Create a project at <https://console.cloud.google.com>
2. **APIs & Services → Library** → enable **Google Drive API** and **Google Sheets API**
3. **OAuth consent screen** → External → fill the required fields
4. **Credentials → Create Credentials → OAuth client ID → Web application**
5. Authorized redirect URI: copy it from the n8n credential screen — usually
   `https://YOUR_N8N_HOST/rest/oauth2-credential/callback`
6. Paste the Client ID and Client Secret into both n8n credentials and click **Connect**

**Publish the consent screen.** While it is in "Testing", Google expires refresh tokens
after 7 days and your pipeline silently stops delivering (PLAN 7.7). Publishing avoids
re-authorising every week.

---

## Where the non-secret settings live

Everything that is not a secret sits in the **Config** node at the top of each workflow,
so you can see and change it without digging through credentials.

| Workflow | Config values to fill |
|---|---|
| all | `supabase_url` |
| 01 | `model_ideation`, `angles_per_topic`, `use_video_gen`, `width`, `height` |
| 02 | `model_script`, `target_duration_sec` |
| 03 | `voice_id`, `tts_model` |
| 04 | `kie_image_model`, `aspect_ratio`, `poll_timeout_minutes` |
| 05 | `kie_video_model`, `negative_prompt`, `poll_timeout_minutes`, `max_scenes` |
| 06 | `shotstack_env`, `show_captions` |
| 07 | `drive_parent_folder_id`, `sheet_id`, `sheet_name`, `cleanup_after_upload` |
| 99 | `stale_minutes` |

`supabase_url` appears in all eight. On self-hosted n8n you can replace the literal with
`={{ $env.SUPABASE_URL }}` and set it once in your environment instead.
