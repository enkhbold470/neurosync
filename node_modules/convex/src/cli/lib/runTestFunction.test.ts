import { expect, test } from "vitest";
import { inlineQueryToQuerySource } from "./runTestFunction.js";

test("wraps inline query expressions in a readonly query module", () => {
  expect(inlineQueryToQuerySource('ctx.db.query("messages").first()'))
    .toBe(`import { query, internalQuery } from "convex:/_system/repl/wrappers.js";

export default query({
  handler: async (ctx) => {
    return (ctx.db.query("messages").first());
  },
});`);
});

test("preserves explicit return bodies", () => {
  expect(
    inlineQueryToQuerySource('return await ctx.db.query("messages").first();'),
  )
    .toBe(`import { query, internalQuery } from "convex:/_system/repl/wrappers.js";

export default query({
  handler: async (ctx) => {
    return await ctx.db.query("messages").first();
  },
});`);
});

test("wraps awaited expressions without changing them", () => {
  expect(inlineQueryToQuerySource('await ctx.db.query("messages").first()'))
    .toBe(`import { query, internalQuery } from "convex:/_system/repl/wrappers.js";

export default query({
  handler: async (ctx) => {
    return (await ctx.db.query("messages").first());
  },
});`);
});

test("preserves multi line statement bodies", () => {
  expect(
    inlineQueryToQuerySource(`const firstMessage = await ctx.db.query("messages").first();
console.log(firstMessage?._id);
return firstMessage;`),
  )
    .toBe(`import { query, internalQuery } from "convex:/_system/repl/wrappers.js";

export default query({
  handler: async (ctx) => {
    const firstMessage = await ctx.db.query("messages").first();
    console.log(firstMessage?._id);
    return firstMessage;
  },
});`);
});

test("preserves full query module source", () => {
  const source = `import { query } from "convex:/_system/repl/wrappers.js";

export default query({
  handler: async (ctx) => {
    return await ctx.db.query("messages").first();
  },
});`;

  expect(inlineQueryToQuerySource(source)).toBe(source);
});

test("injects the wrappers import for full query modules", () => {
  const source = `export default query({
  handler: async (ctx) => {
    return await ctx.db.query("messages").first();
  },
});`;

  expect(inlineQueryToQuerySource(source)).toBe(
    `import { query, internalQuery } from "convex:/_system/repl/wrappers.js";

export default query({
  handler: async (ctx) => {
    return await ctx.db.query("messages").first();
  },
});`,
  );
});
