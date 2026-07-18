declare const REQUEST_ID: unique symbol;
declare const IP: unique symbol;
declare const USER_AGENT: unique symbol;
declare const NOW: unique symbol;
export type LogVar = typeof REQUEST_ID | typeof IP | typeof USER_AGENT | typeof NOW;
export declare const varNames: Record<symbol, string>;
export declare const vars: {
    /** Resolved to the request ID. */
    readonly requestId: typeof REQUEST_ID;
    /** Resolved to the client's IP address. */
    readonly ip: typeof IP;
    /** Resolved to the client's User-Agent header. */
    readonly userAgent: typeof USER_AGENT;
    /**
     * Resolved to the current server timestamp, as milliseconds from the
     * Unix epoch.
     */
    readonly now: typeof NOW;
};
export {};
//# sourceMappingURL=logVars.d.ts.map