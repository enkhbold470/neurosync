// NeuroSync — Convex schema.
//
// SAFETY: this deploys to NeuroSync's OWN deployment, NEVER `avid-guineapig-274` (the landing-page
// waitlist). `convex deploy` replaces the whole functions dir, so deploying this against the waitlist
// deployment would delete `waitlist.ts`. See ../CLOUD_SETUP.md.
//
// Design: local JSON on the Mac stays the source of truth; the cloud is a one-way mirror. Records are
// upserted idempotently by the client-generated UUID, so re-running the upload queue is safe. Epochs
// are chunked (~60/doc) to stay well under Convex's document-size and array limits.
//
// Manifesto invariants preserved in the cloud:
//   • a withheld second is `null`, NEVER 0 — scores are `v.union(v.number(), v.null())`.
//   • `synthetic` + `syntheticNote` travel with every record; the mutations refuse a synthetic
//     record with no note (mirrors Store.write), and synthetic rows are excluded from aggregates.

import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

const brainState = v.union(
  v.literal("focused"), v.literal("daydream"), v.literal("calm"),
  v.literal("clenched"), v.literal("neutral"), v.literal("withheld"),
);

const epoch = v.object({
  t: v.number(),
  focus: v.union(v.number(), v.null()),   // null == withheld, never 0
  calm: v.union(v.number(), v.null()),
  clench: v.union(v.number(), v.null()),
  engagement: v.number(),                 // raw Pope, always present
  bands: v.record(v.string(), v.number()),
  alphaPeak: v.union(v.number(), v.null()),
  rmsUv: v.number(),
  signalOk: v.boolean(),
  fsOk: v.boolean(),
  calibrating: v.boolean(),
  state: brainState,
});

export default defineSchema({
  // Identity mirror. `subject` is the auth provider's stable id (Clerk/Auth0).
  users: defineTable({
    subject: v.string(),
    email: v.string(),
    name: v.optional(v.string()),
    createdAt: v.number(),
  })
    .index("by_subject", ["subject"])
    .index("by_email", ["email"]),

  devices: defineTable({
    userId: v.id("users"),
    name: v.string(),
    firmware: v.optional(v.string()),
    lastSps: v.optional(v.number()),
    lastSeenAt: v.number(),
  }).index("by_user", ["userId"]),

  // One doc per session — metadata only. Epochs live in epochChunks.
  sessions: defineTable({
    userId: v.id("users"),
    clientId: v.string(),                 // Swift SessionRecord.id (UUID) — the upsert key
    schemaVersion: v.number(),
    synthetic: v.boolean(),
    syntheticNote: v.optional(v.string()),
    startedAt: v.number(),
    endedAt: v.number(),
    device: v.object({
      name: v.string(),
      sps: v.number(),
      firmware: v.optional(v.string()),
      afeGain: v.number(),
    }),
    baseline: v.optional(v.object({
      engagement: v.number(),
      clench: v.union(v.number(), v.null()),
      frozenAt: v.number(),
      reused: v.boolean(),
    })),
    coverage: v.number(),
    epochCount: v.number(),
    epochsSynced: v.boolean(),
    updatedAt: v.number(),                // LWW / sync cursor
  })
    .index("by_client", ["clientId"])
    .index("by_user_started", ["userId", "startedAt"]),

  // ~60 epochs per chunk keeps each doc small and the chunk count O(minutes).
  epochChunks: defineTable({
    sessionId: v.id("sessions"),
    userId: v.id("users"),
    chunkIndex: v.number(),               // startSecond = chunkIndex * 60
    epochs: v.array(epoch),
  }).index("by_session_chunk", ["sessionId", "chunkIndex"]),

  focusBlocks: defineTable({
    userId: v.id("users"),
    sessionId: v.id("sessions"),
    clientId: v.string(),                 // ActivitySpan.id
    kind: v.string(),
    source: v.string(),                   // calendar | appWatch | selfReport
    label: v.string(),
    start: v.number(),
    end: v.number(),
    effortful: v.boolean(),
  })
    .index("by_session", ["sessionId"])
    .index("by_user_start", ["userId", "start"]),

  markers: defineTable({
    userId: v.id("users"),
    clientId: v.string(),                 // Marker.id — upsert key
    sessionId: v.optional(v.id("sessions")),
    kind: v.string(),
    at: v.number(),
  })
    .index("by_client", ["clientId"])
    .index("by_user_at", ["userId", "at"]),

  // Derived cache — regenerable, safe to wipe. Not a source of truth.
  dayRollups: defineTable({
    userId: v.id("users"),
    key: v.string(),                      // yyyy-MM-dd
    date: v.number(),
    synthetic: v.boolean(),
    coverage: v.number(),
    findings: v.array(v.object({
      tone: v.string(),
      headline: v.string(),
      caveat: v.string(),
    })),
    computedAt: v.number(),
  }).index("by_user_key", ["userId", "key"]),
});
