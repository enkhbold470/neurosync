// NeuroSync — session sync functions.
//
// Every function is user-scoped: it resolves the caller from `ctx.auth.getUserIdentity()` and refuses
// if unauthenticated. Upserts are idempotent by the client-generated UUID, so the Mac's upload queue
// can retry safely (at-least-once delivery → exactly-once state).

import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import type { Id } from "./_generated/dataModel";

// Resolve (or lazily create) the current user's row from the auth identity.
async function requireUser(ctx: any): Promise<Id<"users">> {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) throw new Error("Not authenticated");
  const existing = await ctx.db
    .query("users")
    .withIndex("by_subject", (q: any) => q.eq("subject", identity.subject))
    .unique();
  if (existing) return existing._id;
  return await ctx.db.insert("users", {
    subject: identity.subject,
    email: identity.email ?? "",
    name: identity.name,
    createdAt: Date.now(),
  });
}

const deviceArg = v.object({
  name: v.string(),
  sps: v.number(),
  firmware: v.optional(v.string()),
  afeGain: v.number(),
});

const baselineArg = v.optional(v.object({
  engagement: v.number(),
  clench: v.union(v.number(), v.null()),
  frozenAt: v.number(),
  reused: v.boolean(),
}));

// Idempotent session upsert, keyed by the Swift SessionRecord.id.
export const upsertSession = mutation({
  args: {
    clientId: v.string(),
    schemaVersion: v.number(),
    synthetic: v.boolean(),
    syntheticNote: v.optional(v.string()),
    startedAt: v.number(),
    endedAt: v.number(),
    device: deviceArg,
    baseline: baselineArg,
    coverage: v.number(),
    epochCount: v.number(),
  },
  handler: async (ctx, args) => {
    // Mirror Store.write: a synthetic record MUST carry a provenance note.
    if (args.synthetic && !args.syntheticNote) {
      throw new Error("A synthetic session must include a syntheticNote.");
    }
    const userId = await requireUser(ctx);
    const now = Date.now();
    const existing = await ctx.db
      .query("sessions")
      .withIndex("by_client", (q: any) => q.eq("clientId", args.clientId))
      .unique();

    if (existing) {
      if (existing.userId !== userId) throw new Error("Session belongs to another user.");
      await ctx.db.patch(existing._id, { ...args, updatedAt: now });
      return existing._id;
    }
    return await ctx.db.insert("sessions", {
      userId,
      ...args,
      epochsSynced: false,
      updatedAt: now,
    });
  },
});

// Upload one chunk of epochs. Idempotent by (sessionId, chunkIndex).
export const upsertEpochChunk = mutation({
  args: {
    clientId: v.string(),
    chunkIndex: v.number(),
    epochs: v.array(v.any()),   // validated by the schema on insert
    isLast: v.boolean(),
  },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    const session = await ctx.db
      .query("sessions")
      .withIndex("by_client", (q: any) => q.eq("clientId", args.clientId))
      .unique();
    if (!session) throw new Error("Unknown session; upsert the session first.");
    if (session.userId !== userId) throw new Error("Session belongs to another user.");

    const existing = await ctx.db
      .query("epochChunks")
      .withIndex("by_session_chunk", (q: any) =>
        q.eq("sessionId", session._id).eq("chunkIndex", args.chunkIndex))
      .unique();
    if (existing) {
      await ctx.db.patch(existing._id, { epochs: args.epochs });
    } else {
      await ctx.db.insert("epochChunks", {
        sessionId: session._id,
        userId,
        chunkIndex: args.chunkIndex,
        epochs: args.epochs,
      });
    }
    if (args.isLast) await ctx.db.patch(session._id, { epochsSynced: true });
    return null;
  },
});

export const upsertMarker = mutation({
  args: {
    clientId: v.string(),
    sessionClientId: v.optional(v.string()),
    kind: v.string(),
    at: v.number(),
  },
  handler: async (ctx, args) => {
    const userId = await requireUser(ctx);
    let sessionId: Id<"sessions"> | undefined;
    if (args.sessionClientId) {
      const s = await ctx.db
        .query("sessions")
        .withIndex("by_client", (q: any) => q.eq("clientId", args.sessionClientId))
        .unique();
      sessionId = s?._id;
    }
    const existing = await ctx.db
      .query("markers")
      .withIndex("by_client", (q: any) => q.eq("clientId", args.clientId))
      .unique();
    if (existing) {
      await ctx.db.patch(existing._id, { kind: args.kind, at: args.at, sessionId });
      return existing._id;
    }
    return await ctx.db.insert("markers", {
      userId, clientId: args.clientId, sessionId, kind: args.kind, at: args.at,
    });
  },
});

// The caller's real (non-synthetic) sessions, most recent first. Paginated — never `.collect()`.
export const listSessions = query({
  args: { paginationOpts: v.any() },
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) return { page: [], isDone: true, continueCursor: "" };
    const user = await ctx.db
      .query("users")
      .withIndex("by_subject", (q: any) => q.eq("subject", identity.subject))
      .unique();
    if (!user) return { page: [], isDone: true, continueCursor: "" };
    const result = await ctx.db
      .query("sessions")
      .withIndex("by_user_started", (q: any) => q.eq("userId", user._id))
      .order("desc")
      .paginate(args.paginationOpts);
    return { ...result, page: result.page.filter((s: any) => !s.synthetic) };
  },
});
