# Demo accounts and data

This standalone site may contain seeded preview users for local demonstrations. Treat any such records as development-only; never enter a real password into the demo flow. Production identity and sessions must use Supabase Auth. Do not copy passwords, tokens, private phone numbers, or service credentials into source control.

## Frontend smoke-test checklist

- Configure a real Supabase project and public anon key in `supabase-config.js`.
- Test signup with `client`, `provider`, and `merchant`; verify profile rows are created.
- Verify signup with `admin` or `moderator` is rejected and direct role escalation is blocked by RLS/trigger.
- Verify country selection populates the correct city list.
- Sign in as a merchant; create, update, hide, show, and delete an ad; verify another merchant cannot change it.
- Use the trusted platform administrator to create an invitation; open it, set matching passwords, accept, then verify reuse/expiry fails.
- Verify only platform-admin users can create/manage admin invitations; verify moderator scope is constrained.
- Update own profile and password (with current password); verify attempts to update other users or privileged fields fail.

Automated browser/database tests require configured Supabase credentials and are not represented as passed until run in a test project.
