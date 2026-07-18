import { describe, it, expect } from "vitest";
import { Command } from "@commander-js/extra-typings";
import { generateDocs, replaceBullets } from "./generateDocs.js";

function makeFakeRoot() {
  const greet = new Command("greet")
    .description("Print a greeting")
    .argument("<name>", "Who to greet")
    .option("-l, --loud", "Shout the greeting");

  const itemAdd = new Command("add")
    .description("Add an item")
    .argument("<name>", "Item name")
    .option("--qty <n>", "Quantity");

  const itemList = new Command("list").alias("ls").description("List items");

  // A sub-subcommand whose leaf name (`create`) collides with `item add`'s
  // sibling group leaf — exercises unique anchor generation for nesting.
  const tokenCreate = new Command("create").description("Create a token");
  const token = new Command("token")
    .description("Manage tokens")
    .addCommand(tokenCreate);

  const itemCreate = new Command("create").description("Create an item");

  const item = new Command("item")
    .description("Manage items")
    .addCommand(itemAdd)
    .addCommand(itemList)
    .addCommand(itemCreate)
    .addCommand(token);

  // A description whose body is an indented numbered list, like `convex dev`.
  // These steps must render as a real ordered list, not bullets wrapping
  // ordered-list items (which renders as roman numerals).
  const steps = new Command("steps")
    // Has no registered arguments, so its custom `.usage()` is preserved
    // verbatim in the generated Usage line.
    .usage("<command> [options]")
    .description(
      "Do things in order\n\n" + "  1. First step\n" + "  2. Second step\n",
    );

  // Mixes a code-span placeholder (must stay literal, no backslash) with a
  // bare prose placeholder (must be escaped so MDX doesn't parse it as JSX).
  const escape = new Command("escape").description(
    "The positional `<nameOrToken>` is set by --team <team_slug>",
  );

  // Exercises rendering `npx convex ...` code spans in list items as copy
  // buttons, while leaving code spans in plain prose lines untouched.
  const envLike = new Command("envLike").description(
    "- Set a variable: `npx convex env set NAME 'value'`\n" +
      "Unrelated span: `npx convex run foo`",
  );

  // A description with a 3-level nested bullet list followed by a prose-led
  // numbered list, like `convex deploy`. The nested sub-items (indented 2 and 4
  // spaces) must keep their nesting, while the prose-led numbered list must be
  // dedented to the left margin so it interrupts the paragraph.
  const nested = new Command("nested").description(
    [
      "Pick a target like this:",
      "- If FOO is set, use the default.",
      "- If BAR is set, use its deployment.",
      "  - When it's a preview key, deploy to a preview deployment:",
      "    - with the current Git branch name in CI",
      "    - or with the name from `--preview-name`",
      "",
      "Then it will:",
      "  1. Typecheck your functions.",
      "  2. Push to the deployment.",
    ].join("\n"),
  );

  const secret = new Command("secret").description("Hidden command");

  // Overrides `.usage()` to show its args as required (for nicer `--help`)
  // even though they're registered as optional. The docs must reflect the
  // registered optionality, not the override.
  const config = new Command("config")
    .description("Set config")
    .usage("[options] <key> <value>")
    .argument("[key]", "The config key")
    .argument("[value]", "The value; omit to set interactively");

  return new Command("fake")
    .description("A fake CLI for testing generateDocs")
    .usage("<command> [options]")
    .addCommand(greet)
    .addCommand(item)
    .addCommand(config)
    .addCommand(steps)
    .addCommand(escape)
    .addCommand(envLike)
    .addCommand(nested)
    .addCommand(secret, { hidden: true });
}

describe("generateDocs", () => {
  it("creates one file per visible main command and no root index", () => {
    const docs = generateDocs(makeFakeRoot());
    const paths = Object.keys(docs).sort();
    expect(paths).toEqual([
      "config.mdx",
      "envLike.mdx",
      "escape.mdx",
      "greet.mdx",
      "item.mdx",
      "nested.mdx",
      "steps.mdx",
    ]);
    expect(docs["index.mdx"]).toBeUndefined();
  });

  it("does not emit a file for hidden subcommands", () => {
    const docs = generateDocs(makeFakeRoot());
    expect(docs["secret.mdx"]).toBeUndefined();
  });

  it("renders the command name as a heading with the npx prefix", () => {
    const docs = generateDocs(makeFakeRoot());
    expect(docs["greet.mdx"]).toContain("# `npx fake greet`");
    expect(docs["greet.mdx"]).toContain("Print a greeting");
  });

  it("includes a @generated marker comment in every file", () => {
    const docs = generateDocs(makeFakeRoot());
    for (const md of Object.values(docs)) {
      expect(md).toContain(
        "{/* @generated from the command definitions, do not edit manually (run `just regenerate-cli-docs` to regenerate) */}",
      );
    }
  });

  it("emits sidebar_position frontmatter matching command definition order", () => {
    const docs = generateDocs(makeFakeRoot());
    expect(docs["greet.mdx"]).toMatch(/^---\nsidebar_position: 1\n/);
    expect(docs["item.mdx"]).toMatch(/^---\nsidebar_position: 2\n/);
  });

  it("emits a title frontmatter with the full npx command so the page <title> isn't just the file name", () => {
    const docs = generateDocs(makeFakeRoot());
    expect(docs["greet.mdx"]).toMatch(/\ntitle: "npx fake greet"\n/);
    expect(docs["item.mdx"]).toMatch(/\ntitle: "npx fake item"\n/);
  });

  it("emits a description frontmatter carrying the command summary", () => {
    const docs = generateDocs(makeFakeRoot());
    expect(docs["greet.mdx"]).toMatch(/\ndescription: "Print a greeting"\n/);
    expect(docs["item.mdx"]).toMatch(/\ndescription: "Manage items"\n/);
  });

  it("uses `npx` in usage lines", () => {
    const md = generateDocs(makeFakeRoot())["greet.mdx"];
    expect(md).toMatch(/```sh\nnpx fake greet/);
  });

  it("documents arguments and options", () => {
    const md = generateDocs(makeFakeRoot())["greet.mdx"];
    expect(md).toContain("## Arguments");
    expect(md).toContain("<name>");
    expect(md).toContain("Who to greet");
    expect(md).toContain("## Options");
    expect(md).toContain("-l, --loud");
  });

  it("renders descendant subcommands as h2 sections with an id matching the leaf name", () => {
    const md = generateDocs(makeFakeRoot())["item.mdx"];
    expect(md).toContain("## `npx fake item add` \\{#add}");
    expect(md).toContain("## `npx fake item list` \\{#list}");
    expect(md).toContain("### Usage");
  });

  it("documents aliases for nested subcommands inside the main command file", () => {
    const md = generateDocs(makeFakeRoot())["item.mdx"];
    expect(md).toContain("### Aliases");
    expect(md).toContain("`ls`");
  });

  it("links nested subcommand list entries to in-page anchors", () => {
    const md = generateDocs(makeFakeRoot())["item.mdx"];
    expect(md).toContain("## Subcommands");
    expect(md).toContain("[`npx fake item add`](#add)");
    expect(md).toContain("[`npx fake item list`](#list)");
  });

  it("gives sub-subcommands a path-based anchor so leaf names don't collide", () => {
    const md = generateDocs(makeFakeRoot())["item.mdx"];
    // `item create` keeps the bare leaf anchor...
    expect(md).toContain("## `npx fake item create` \\{#create}");
    // ...while `item token create` is namespaced to avoid a duplicate `#create`.
    expect(md).toContain("### `npx fake item token create` \\{#token-create}");
    expect(md).not.toContain("`npx fake item token create` \\{#create}");
  });

  it("renders sub-subcommands at a deeper heading level than their parent group", () => {
    const md = generateDocs(makeFakeRoot())["item.mdx"];
    // `item token` is a direct subcommand (h2)...
    expect(md).toContain("## `npx fake item token` \\{#token}");
    // ...and its child `item token create` nests one level deeper (h3).
    expect(md).toContain("### `npx fake item token create` \\{#token-create}");
  });

  it("produces unique heading anchor ids within a file", () => {
    const md = generateDocs(makeFakeRoot())["item.mdx"];
    const anchors = [...md.matchAll(/\\\{#([\w-]+)}/g)].map((m) => m[1]);
    expect(new Set(anchors).size).toBe(anchors.length);
  });

  it("links sub-subcommand list entries to their path-based anchors", () => {
    const md = generateDocs(makeFakeRoot())["item.mdx"];
    // `token` is a direct child of `item`, listed in item's Subcommands.
    expect(md).toContain("[`npx fake item token`](#token)");
  });

  it("derives the usage line from registered argument optionality, ignoring a conflicting .usage() override", () => {
    const md = generateDocs(makeFakeRoot())["config.mdx"];
    // The command overrides .usage() with `<key> <value>`, but the args are
    // registered as optional, so the Usage line must match the Arguments
    // section (`[key]`/`[value]`) rather than the override.
    expect(md).toContain("```sh\nnpx fake config [options] [key] [value]\n```");
    expect(md).not.toContain("<key> <value>");
    expect(md).toContain("`[key]`");
    expect(md).toContain("`[value]`");
  });

  it("keeps the .usage() override for commands with no registered arguments", () => {
    // `steps` has no positional args, so its custom `<command> [options]`
    // usage is preserved verbatim.
    const md = generateDocs(makeFakeRoot())["steps.mdx"];
    expect(md).toContain("```sh\nnpx fake steps <command> [options]\n```");
  });

  it("renders an indented numbered description as an ordered list, not bullets", () => {
    const md = generateDocs(makeFakeRoot())["steps.mdx"];
    expect(md).toContain("1. First step");
    expect(md).toContain("2. Second step");
    // Must not wrap the ordered-list items in bullets (renders as roman numerals).
    expect(md).not.toContain("- 1. First step");
  });

  it("preserves the nesting of a multi-level list that follows list items", () => {
    const md = generateDocs(makeFakeRoot())["nested.mdx"];
    // Top-level items stay at the left margin.
    expect(md).toContain("\n- If BAR is set, use its deployment.\n");
    // The 2-space sub-item stays nested under its parent (not flattened to the
    // left margin, which was the bug when deeper-indented lines flushed early).
    expect(md).toContain(
      "\n  - When it's a preview key, deploy to a preview deployment:\n",
    );
    expect(md).not.toContain("\n- When it's a preview key");
    // The 4-space sub-sub-items keep their deeper nesting.
    expect(md).toContain("\n    - with the current Git branch name in CI\n");
    expect(md).toContain("\n    - or with the name from `--preview-name`\n");
  });

  it("dedents a prose-led numbered list to the left margin so it interrupts the paragraph", () => {
    const md = generateDocs(makeFakeRoot())["nested.mdx"];
    // The numbered list follows prose ("Then it will:"), so it must be dedented
    // to the left margin to render as an ordered list rather than collapsing
    // into the preceding paragraph.
    expect(md).toContain("\n1. Typecheck your functions.\n");
    expect(md).toContain("\n2. Push to the deployment.\n");
    expect(md).not.toContain("  1. Typecheck your functions.");
  });

  it("escapes JSX-like placeholders in prose but leaves inline code spans alone", () => {
    const md = generateDocs(makeFakeRoot())["escape.mdx"];
    // Inside backticks `<nameOrToken>` is already literal — no backslash.
    expect(md).toContain("`<nameOrToken>`");
    expect(md).not.toContain("`\\<nameOrToken>`");
    // In prose, the bare placeholder is escaped so MDX won't parse it as a tag.
    expect(md).toContain("--team \\<team_slug>");
  });

  it("renders `npx convex ...` code spans in list items as CodeWithCopyButton, leaving prose spans as code", () => {
    const md = generateDocs(makeFakeRoot())["envLike.mdx"];
    // Commands in list items become copy buttons.
    expect(md).toContain(
      `<CodeWithCopyButton text={"npx convex env set NAME 'value'"} />`,
    );
    // Code spans outside of list items stay as inline code.
    expect(md).toContain("`npx convex run foo`");
    expect(md).not.toContain(`text={"npx convex run foo"}`);
  });
});

describe("replaceBullets", () => {
  it("replaces a leading `• ` bullet with `- `", () => {
    expect(replaceBullets("• an item")).toBe("- an item");
  });

  it("preserves leading indentation", () => {
    expect(replaceBullets("  • an item")).toBe("  - an item");
    expect(replaceBullets("    • a deeper item")).toBe("    - a deeper item");
  });

  it("replaces bullets on every line of a multi-line string", () => {
    const input = "• first\n• second\n  • nested";
    expect(replaceBullets(input)).toBe("- first\n- second\n  - nested");
  });

  it("leaves lines without a `• ` bullet untouched", () => {
    const input = "Plain prose\nAnother line";
    expect(replaceBullets(input)).toBe(input);
  });

  it("only replaces bullets at the start of a line, not mid-line", () => {
    expect(replaceBullets("a • b")).toBe("a • b");
  });

  it("requires a space after the bullet", () => {
    expect(replaceBullets("•noSpace")).toBe("•noSpace");
  });

  it("collapses only the single space following the bullet", () => {
    // Extra spaces after the `• ` are preserved.
    expect(replaceBullets("•  two spaces")).toBe("-  two spaces");
  });

  it("returns an empty string unchanged", () => {
    expect(replaceBullets("")).toBe("");
  });
});
