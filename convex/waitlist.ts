// VENDORED VERBATIM from neurofocus-finc/convex/waitlist.ts.
//
// This deployment (avid-guineapig-274) is SHARED with the landing page, and `convex deploy` replaces
// the whole functions dir. So NeuroSync's convex/ must be a SUPERSET that includes the waitlist —
// otherwise deploying from here would delete it. Keep these functions byte-identical to the landing
// page's, and keep NeuroSync as the SOLE deployer of this deployment (the landing page must not run
// `convex deploy`). See ../CLOUD_SETUP.md.

import { mutation, internalMutation, query } from './_generated/server';
import { v } from 'convex/values';

/**
 * Total number of people on the waitlist. Convex caches this and only
 * recomputes it when the `waitlist` table changes, so it's cheap to read on
 * every page load. Returns the real count — never a seeded baseline.
 */
export const count = query({
	args: {},
	handler: async (ctx) => {
		const rows = await ctx.db.query('waitlist').collect();
		return rows.length;
	}
});

/**
 * Capture a waitlist signup. Idempotent by email: a repeat signup updates the
 * existing row rather than creating a duplicate, so the table stays one-row-per-person.
 */
export const addSignup = mutation({
	args: {
		name: v.string(),
		email: v.string(),
		org: v.optional(v.string()),
		message: v.optional(v.string())
	},
	handler: async (ctx, args) => {
		const email = args.email.toLowerCase();
		const fields = {
			name: args.name,
			email,
			org: args.org,
			message: args.message
		};

		const existing = await ctx.db
			.query('waitlist')
			.withIndex('by_email', (q) => q.eq('email', email))
			.unique();

		if (existing) {
			await ctx.db.patch(existing._id, fields);
			return { deduped: true };
		}

		await ctx.db.insert('waitlist', { ...fields, joinedAt: Date.now() });
		return { deduped: false };
	}
});

/**
 * Bulk-import historical signups (e.g. migrating an old Google Form export).
 * Internal-only — not callable from the public API; run it with
 * `bunx convex run waitlist:importBatch '<json>'`. Idempotent by email: an
 * existing person is updated (and their original `joinedAt` preserved) rather
 * than duplicated, so it's safe to re-run.
 */
export const importBatch = internalMutation({
	args: {
		rows: v.array(
			v.object({
				name: v.string(),
				email: v.string(),
				joinedAt: v.optional(v.number())
			})
		)
	},
	handler: async (ctx, { rows }) => {
		let inserted = 0;
		let updated = 0;
		for (const row of rows) {
			const email = row.email.toLowerCase();
			const existing = await ctx.db
				.query('waitlist')
				.withIndex('by_email', (q) => q.eq('email', email))
				.unique();
			if (existing) {
				await ctx.db.patch(existing._id, { name: row.name });
				updated++;
			} else {
				await ctx.db.insert('waitlist', { name: row.name, email, joinedAt: row.joinedAt });
				inserted++;
			}
		}
		return { inserted, updated };
	}
});
