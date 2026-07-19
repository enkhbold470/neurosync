// Clerk auth for Convex. `CLERK_FRONTEND_API_URL` is set in the Convex dashboard
// (Settings ▸ Environment Variables) and mirrored in `.env`. `applicationID` must match the name of
// the JWT template you create in Clerk ("convex"). See CLOUD_SETUP.md.
export default {
  providers: [
    {
      domain: process.env.CLERK_FRONTEND_API_URL,
      applicationID: "convex",
    },
  ],
};
