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

## ✅ What is already DONE (path A — separate deployment)
- **Separate NeuroSync deployment** created: project `neurosync` in team `inky-team`, dev deployment
  **`gregarious-leopard-890`** (`https://gregarious-leopard-890.convex.cloud`). Fully isolated from
  the landing page's `avid-guineapig-274`.
- **Schema + functions deployed** there (users/devices/sessions/epochChunks/focusBlocks/markers/
  dayRollups + the vendored waitlist), with all indexes.
- **Clerk configured:** `CLERK_FRONTEND_API_URL=https://adjusted-oryx-8.clerk.accounts.dev` set on the
  deployment; **JWT template `convex`** created (`claims: {"aud":"convex"}`, 60 s lifetime).
- **App wired:** `CONVEX_URL` + `CLERK_PUBLISHABLE_KEY` ship in the asset-catalog `CloudConfig` data
  set (public-safe). Cloud is forced OFF under the test host (`CloudConfig.isRunningTests`).
- **Landing page restored + verified:** `avid-guineapig-274` was redeployed from `neurofocus-finc`
  (blog `posts.js`/`files.js` back), waitlist = 26, blog query works.

## ⏳ What REMAINS (needs your Clerk dashboard / a real sign-in test)
The plumbing is done, but auth can only be *verified* by a real interactive sign-in:
1. In the **Clerk dashboard** (instance `adjusted-oryx-8`), confirm **email sign-up/sign-in is
   enabled**, and — if ClerkKit's native flow requires it — register this app's bundle id
   `com.inkyg.neurosync` under **Native Applications**. (The `convex` JWT template already exists.)
2. **Run the app** (from Xcode) and sign in via the glass "Sign in to sync" button. Then confirm a
   real session appears in the dashboard: `https://dashboard.convex.dev/d/gregarious-leopard-890`.
3. To promote from the **dev** deployment to a **prod** one later: `npx convex deploy` (creates the
   project's prod deployment), set `CLERK_FRONTEND_API_URL` on prod too, and swap the `CONVEX_URL` in
   `Assets.xcassets/CloudConfig.dataset/CloudConfig.json` to the prod URL.

## How the app reads its config
`CloudConfig` reads `CONVEX_URL` + `CLERK_PUBLISHABLE_KEY` from, in order: the bundled asset-catalog
`CloudConfig` data set (what ships today) → Info.plist → environment. Both values are public-safe.
When both are present (and not under tests) the header shows **"Sign in to sync"**; after sign-in,
real sessions mirror to Convex automatically (never synthetic ones; `null` withheld scores preserved).

## Rotate the shared secrets
The deploy key + team token pasted in chat should be rotated in the Convex dashboard; update `.env`.
