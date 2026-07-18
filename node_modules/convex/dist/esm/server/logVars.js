"use strict";
const REQUEST_ID = Symbol("var.requestId");
const IP = Symbol("var.ip");
const USER_AGENT = Symbol("var.userAgent");
const NOW = Symbol("var.now");
export const varNames = {
  [REQUEST_ID]: "requestId",
  [IP]: "ip",
  [USER_AGENT]: "userAgent",
  [NOW]: "now"
};
export const vars = {
  /** Resolved to the request ID. */
  requestId: REQUEST_ID,
  /** Resolved to the client's IP address. */
  ip: IP,
  /** Resolved to the client's User-Agent header. */
  userAgent: USER_AGENT,
  /**
   * Resolved to the current server timestamp, as milliseconds from the
   * Unix epoch.
   */
  now: NOW
};
//# sourceMappingURL=logVars.js.map
