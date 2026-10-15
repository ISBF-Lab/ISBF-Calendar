# Production identity test dependency

This is an unmodified, fixed snapshot of `plugins/discourse-academy-roles` from
the private `ISBF-Lab/ISBFweb` production commit
`132cc95d043db01251eedf9c93b3927cd5ffee91`.

It is retained in the same organisation's private Calendar repository solely to
test the real identity/Guardian contract without granting CI cross-repository
credentials. `production-identity.json` records every source SHA-256. No identity
behavior is mocked or changed. The source remains covered by the upstream
Discourse licence; its original headers and files are preserved.

CI copies this dependency into the test Core's plugin directory before boot.
Production release packages exclude `test/`; the installed identity plugin is
never replaced by this fixture. Updating the dependency requires an explicit
source-commit and hash review.
