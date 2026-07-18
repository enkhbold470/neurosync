import { describe, expect, test } from "vitest";
import { AuditLogBody, cloneWithSentinels } from "./audit_logging.js";
import { log } from "./log.js";

describe("cloneWithSentinels", () => {
  test("clones the body when there are no log vars", () => {
    const input: AuditLogBody = {
      foo: "bar",
      count: 42,
      flag: true,
      empty: null,
      nested: { inner: "value", arr: [1, 2, 3] },
    };
    const result = cloneWithSentinels(input);

    expect(result).toEqual(input);
    expect(result).not.toBe(input);
    expect(result.nested).not.toBe(input.nested);
  });

  test("replaces log vars with sentinel objects", () => {
    const input: AuditLogBody = {
      userIp: log.vars.ip,
      agent: log.vars.userAgent,
      ts: log.vars.now,
      reqId: log.vars.requestId,
      note: "hello",
    };
    const result = cloneWithSentinels(input);

    expect(result).toEqual({
      userIp: { $var: "ip" },
      agent: { $var: "userAgent" },
      ts: { $var: "now" },
      reqId: { $var: "requestId" },
      note: "hello",
    });
  });

  test("handles log vars nested inside an object", () => {
    const input: AuditLogBody = {
      outer: {
        inner: {
          userIp: log.vars.ip,
          ts: log.vars.now,
        },
        label: "x",
      },
    };
    const result = cloneWithSentinels(input);

    expect(result).toEqual({
      outer: {
        inner: { userIp: { $var: "ip" }, ts: { $var: "now" } },
        label: "x",
      },
    });
  });

  test("handles log vars inside arrays", () => {
    const input: AuditLogBody = {
      items: [log.vars.ip, log.vars.userAgent, log.vars.now, "literal"],
    };
    const result = cloneWithSentinels(input);

    expect(result).toEqual({
      items: [
        { $var: "ip" },
        { $var: "userAgent" },
        { $var: "now" },
        "literal",
      ],
    });
  });

  test("handles the same var used multiple times", () => {
    const input: AuditLogBody = {
      topIp: log.vars.ip,
      nested: { anotherIp: log.vars.ip },
      list: [log.vars.ip],
    };
    const result = cloneWithSentinels(input);

    expect(result).toEqual({
      topIp: { $var: "ip" },
      nested: { anotherIp: { $var: "ip" } },
      list: [{ $var: "ip" }],
    });
  });

  test("handles log vars inside objects within an array", () => {
    const input: AuditLogBody = {
      records: [
        { ip: log.vars.ip, name: "a" },
        { ts: log.vars.now, name: "b" },
        { agent: log.vars.userAgent, name: "c" },
      ],
    };
    const result = cloneWithSentinels(input);

    expect(result).toEqual({
      records: [
        { ip: { $var: "ip" }, name: "a" },
        { ts: { $var: "now" }, name: "b" },
        { agent: { $var: "userAgent" }, name: "c" },
      ],
    });
  });

  test("throws on keys starting with $", () => {
    expect(() => cloneWithSentinels({ $var: "ip" })).toThrow(
      'keys must not start with "$"',
    );
  });

  test("throws on $ keys nested inside objects", () => {
    expect(() => cloneWithSentinels({ outer: { $secret: "value" } })).toThrow(
      'keys must not start with "$"',
    );
  });

  test("throws on unknown symbol var", () => {
    const fakeVar = Symbol("var.fake");
    expect(() =>
      // @ts-expect-error intentionally passing an invalid var symbol
      cloneWithSentinels({ x: fakeVar }),
    ).toThrow("Unknown audit var symbol");
  });
});
