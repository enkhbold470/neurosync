/* eslint-disable @typescript-eslint/no-unused-vars */
import { assert, Equals } from "../test/type_testing.js";
import { test } from "vitest";
import {
  ApiFromModules,
  FilterApi,
  FunctionReference,
  FunctionReferenceFromExport,
} from "./api.js";
import {
  EmptyObject,
  RegisteredAction,
  RegisteredMutation,
  RegisteredQuery,
} from "./registration.js";

test("FunctionReferenceFromExport preserves visibility through intersections", () => {
  type TaggedPublicMutation = RegisteredMutation<
    "public",
    EmptyObject,
    string
  > & { foo: "bar" };
  type TaggedInternalMutation = RegisteredMutation<
    "internal",
    EmptyObject,
    string
  > & { foo: "bar" };
  type TaggedInternalQuery = RegisteredQuery<
    "internal",
    { x: number },
    string
  > & { tag: true };
  type TaggedPublicAction = RegisteredAction<"public", EmptyObject, number> & {
    a: 1;
  };

  assert<
    Equals<
      FunctionReferenceFromExport<TaggedPublicMutation>,
      FunctionReference<"mutation", "public", EmptyObject, string>
    >
  >();
  assert<
    Equals<
      FunctionReferenceFromExport<TaggedInternalMutation>,
      FunctionReference<"mutation", "internal", EmptyObject, string>
    >
  >();
  assert<
    Equals<
      FunctionReferenceFromExport<TaggedInternalQuery>,
      FunctionReference<"query", "internal", { x: number }, string>
    >
  >();
  assert<
    Equals<
      FunctionReferenceFromExport<TaggedPublicAction>,
      FunctionReference<"action", "public", EmptyObject, number>
    >
  >();
});

test("intersected functions show up in api / internal", () => {
  type TaggedInternal = RegisteredMutation<"internal", EmptyObject, string> & {
    foo: "bar";
  };
  type TaggedPublic = RegisteredMutation<"public", EmptyObject, number> & {
    tag: true;
  };

  const myModule = {
    taggedInternal: null as unknown as TaggedInternal,
    taggedPublic: null as unknown as TaggedPublic,
  };
  type API = ApiFromModules<{ myModule: typeof myModule }>;
  type Internal = FilterApi<API, FunctionReference<any, "internal">>;
  type Public = FilterApi<API, FunctionReference<any, "public">>;

  assert<
    Equals<
      Internal,
      {
        myModule: {
          taggedInternal: FunctionReference<
            "mutation",
            "internal",
            EmptyObject,
            string
          >;
        };
      }
    >
  >();
  assert<
    Equals<
      Public,
      {
        myModule: {
          taggedPublic: FunctionReference<
            "mutation",
            "public",
            EmptyObject,
            number
          >;
        };
      }
    >
  >();
});
