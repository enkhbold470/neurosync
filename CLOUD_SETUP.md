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

## ⚠️ Deployment safety (read once)
Your `.env` points `CONVEX_URL` / `CONVEX_DEPLOY_KEY` at **`avid-guineapig-274`**, the deployment that
also hosts the landing-page **waitlist (24 signups, confirmed)**. `convex deploy` replaces the whole
functions dir — so NeuroSync's `convex/` is a **superset** that vendors `waitlist.ts` + the waitlist
table. Deploying from here therefore keeps the waitlist. **The rule: NeuroSync is now the SOLE deployer
of `avid-guineapig-274`. The landing page (`neurofocus-finc`) must NOT run `convex deploy` anymore**
(it would drop NeuroSync's tables). Keep `convex/waitlist.ts` byte-identical across both repos.

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
# 3. deploy NeuroSync's functions (waitlist included → cannot be dropped)
npx convex deploy
# 4. verify the waitlist is STILL 24 AFTER
npx convex run waitlist:count '{}'          # -> 24
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
