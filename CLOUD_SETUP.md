# NeuroSync cloud sync — setup

NeuroSync is **local-first**. The JSON at `~/Desktop/neurosync-local/` is the source of truth; the
cloud is an **opt-in one-way mirror**. With no `CONVEX_URL` / Clerk key configured and nobody signed
in, the app behaves exactly as before — no network, no account. This is how to turn the mirror on.

## What's already built + validated
- **Backend `convex/`** — `schema.ts` (users/devices/sessions/epochChunks/focusBlocks/markers/dayRollups
  **+ the vendored `waitlist` table**), `sessions.ts` (user-scoped, idempotent upserts; epochs chunked
  ~60/doc; `null` withheld scores preserved; synthetic refused), `waitlist.ts` (byte-identical vendor
  of the landing page's), `auth.config.ts` (Clerk). `npx convex codegen` bundles it cleanly.
- **App** — ConvexMobile + ClerkConvex + ClerkKit/UI are wired. `Cloud/ConvexClerk.swift` builds the
  authed client + the real uploader; `UI/CloudSyncButton.swift` is the glass sign-in; it's all gated
  behind `CloudConfig.canOfferSync`, so the app stays local-first until configured.
- **`network.client` entitlement**; `.env` / `.env.example`.

## ⚠️ Deployment safety (read once — this is a real hazard)
Your `.env` points `CONVEX_URL` / `CONVEX_DEPLOY_KEY` at **`avid-guineapig-274`**, which is the
landing page's LIVE deployment. `convex deploy` replaces the **whole** functions dir and schema, so
deploying NeuroSync's `convex/` there overwrites everything the landing page has. The landing page
runs MORE than the waitlist:

| Landing-page function/table | Vendored into NeuroSync's `convex/`? |
|---|---|
| `waitlist` table + `waitlist.ts` (count/addSignup/importBatch) | ✅ yes (byte-identical) |
| `posts` table + `posts.ts` (blog: list/get/create/update/remove/views) | ❌ **NO** |
| `files.ts` (generateUploadUrl/getUrl) | ❌ **NO** |

**So deploying NeuroSync's current `convex/` to `avid-guineapig-274` would DELETE the live blog +
file-upload functions and try to drop the `posts` table.** The "superset" only ever covered the
waitlist. Do **not** deploy there as-is.

**Two safe paths (pick one — this is a product decision, it touches the live site):**
- **(A, recommended) A separate NeuroSync deployment.** Create a fresh Convex project/deployment,
  point `CONVEX_URL`/`CONVEX_DEPLOY_KEY` at it, deploy NeuroSync's `convex/` there. Zero risk to the
  landing page. Clean separation. This is what the original plan called for.
- **(B) True superset on the shared deployment.** Vendor the ENTIRE landing-page backend
  (`posts.ts`, `files.ts`, the `posts` table) into NeuroSync's `convex/` too, making NeuroSync the
  SOLE deployer of `avid-guineapig-274` forever (the landing page must never `convex deploy` again).
  Workable but fragile — every landing-page backend change must be re-vendored here before deploying.

## The 3 values you must provide (from Clerk)
Deploy is currently blocked (safely) until Clerk is set — `codegen`/`deploy` refuse because
`auth.config.ts` needs `CLERK_FRONTEND_API_URL`. Your Clerk app id is `app_3Gg4jC7kkLaOz8Z0mTflMy5D01e`.
1. In Clerk: enable **Native API**, add a **JWT template named `convex`**, add this macOS app's
   **bundle id** (`com.inkyg.neurosync`) under Native Applications, and add the associated-domain
   `webcredentials:<your-frontend-api>`.
2. Grab **`CLERK_PUBLISHABLE_KEY`** and the **Frontend API URL** from the Clerk dashboard.

## Turn it on
```bash
cd /Users/inky/Desktop/neurofocus-brain/neurosync
# 1. Clerk frontend API URL → the Convex deployment's env (needed before deploy)
npx convex env set CLERK_FRONTEND_API_URL "https://<your-frontend-api>.clerk.accounts.dev"
# 2. verify the waitlist is untouched BEFORE
npx convex run waitlist:count '{}'          # -> 24
# 3. deploy — ONLY to a SEPARATE NeuroSync deployment (path A), OR after vendoring the FULL
#    landing-page backend (path B). NEVER deploy the current convex/ to avid-guineapig-274:
#    it would delete the blog (posts.ts/files.ts) and drop the posts table.
npx convex deploy
# 4. verify the waitlist AND the blog are untouched AFTER
npx convex run waitlist:count '{}'          # -> 24
npx convex run posts:listPublished '{}'     # -> the blog posts, unchanged
```

## Point the app at the deployment
The app reads `CONVEX_URL` + `CLERK_PUBLISHABLE_KEY` from its Info.plist (or the scheme's environment
for dev). Add both to the `neurosync` target (Xcode ▸ target ▸ Info, or `INFOPLIST_KEY_CONVEX_URL` /
`INFOPLIST_KEY_CLERK_PUBLISHABLE_KEY` build settings — both are public-safe to commit):
```
CONVEX_URL = https://avid-guineapig-274.convex.cloud
CLERK_PUBLISHABLE_KEY = pk_...
```
Once both are set, the header shows **“Sign in to sync”**; after sign-in, real sessions mirror to
Convex automatically (never synthetic ones, `null` withheld scores preserved).

## Rotate the shared secrets
The deploy key + team token pasted in chat should be rotated in the Convex dashboard; update `.env`.
