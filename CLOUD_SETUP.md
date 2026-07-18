# NeuroSync cloud sync — setup

NeuroSync is **local-first**. The JSON at `~/Desktop/neurosync-local/` is the source of truth; the
cloud is an **opt-in one-way mirror**. With no `CONVEX_URL` configured and nobody signed in, the app
behaves exactly as before — no network, no account. This doc is how to turn the mirror on.

> ⚠️ **Never deploy NeuroSync's Convex functions to `avid-guineapig-274`.** That deployment hosts the
> landing-page **waitlist**, and `convex deploy` *replaces the entire functions directory* — it would
> delete `waitlist.ts`. NeuroSync gets its **own** deployment. The keys shared in chat should be
> **rotated**; put the fresh ones in `.env` (gitignored).

## What's already in the repo
- `convex/schema.ts`, `convex/sessions.ts` — the backend (user-scoped, idempotent upserts, epochs
  chunked ~60/doc, `null` withheld scores preserved, synthetic sessions refused/excluded).
- `package.json` — `npm run dev` / `npm run deploy`.
- `neurosync/Cloud/` — `CloudConfig`, `CloudSync` (the local-first upload queue + `CloudUploader`
  seam). Wired in `ContentView.task`, gated OFF until configured.
- `com.apple.security.network.client` entitlement (for the WebSocket).
- `.env` / `.env.example`.

## 1. Create NeuroSync's own deployment
```bash
cd /Users/inky/Desktop/neurofocus-brain/neurosync
npm install
npx convex dev        # interactive: choose "create a new project" → name it "neurosync"
```
This creates a fresh deployment, writes its URL, and generates `convex/_generated/`. Copy the new
deployment URL + a deploy key into `.env` (`CONVEX_URL`, `CONVEX_DEPLOY_KEY`). Confirm the URL is
**not** `avid-guineapig-274`.

## 2. Deploy the schema + functions
```bash
npx convex deploy     # pushes schema.ts + sessions.ts to NeuroSync's deployment ONLY
```
Schema changes are additive; the waitlist deployment is never touched.

## 3. Email auth (Clerk)
1. Create a Clerk app, enable **Email** sign-up. Add a JWT template named `convex`.
2. In `convex/auth.config.ts`:
   ```ts
   export default { providers: [{ domain: process.env.CLERK_FRONTEND_API_URL, applicationID: "convex" }] };
   ```
   Set `CLERK_FRONTEND_API_URL` in the Convex dashboard env + `.env`.
3. In Xcode: **File ▸ Add Package Dependencies…** →
   `https://github.com/clerk/clerk-convex-swift` (and `https://github.com/get-convex/convex-swift`).
   **Verify both build for the macOS target** (Clerk's SDK is iOS-documented — if macOS is
   unsupported, use `https://github.com/get-convex/convex-swift-auth0` instead).

## 4. Wire the real uploader
Implement `CloudUploader` (see `neurosync/Cloud/CloudSync.swift`) with `ConvexClientWithAuth`:
chunk `record.epochs` into 60s groups and call `sessions.upsertSession` then `sessions.upsertEpochChunk`
(`isLast: true` on the final chunk). Pass it into `CloudSyncController(store:uploader:)` in
`ContentView.task`. Add a glass sign-in surface (use `InstrumentButton` + `Ink` tokens).

## 5. Point the app at the deployment
Add a build setting / Info.plist key `CONVEX_URL` = your new deployment URL (or export it in the
scheme's environment for dev). `CloudConfig` reads it; once set and signed in, `syncPending()` starts
mirroring local sessions (never synthetic ones).

## Verify it can't hurt the waitlist
```bash
# waitlist count before/after any NeuroSync deploy must be unchanged:
curl -s https://avid-guineapig-274.convex.site/api/... # or the landing page's /api/waitlist
```
