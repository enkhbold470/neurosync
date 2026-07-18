import { Context } from "../../../bundler/context.js";
import { LocalDeploymentKind } from "./filePaths.js";
export declare function handlePotentialUpgradeAndStart(ctx: Context, args: {
    deploymentKind: LocalDeploymentKind;
    deploymentName: string;
    oldVersion: string | null;
    newBinaryPath: string;
    newVersion: string;
    ports: {
        cloud: number;
        site: number;
    };
    existingCredentials: {
        adminKey: string;
        instanceSecret: string;
    } | null;
    forceUpgrade: boolean;
    cloudProjectId: number | undefined;
}): Promise<{
    cleanupHandle: string;
    adminKey: string;
}>;
//# sourceMappingURL=upgrade.d.ts.map