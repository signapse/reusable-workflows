# Prodzilla's event router is stateless

To make Prodzilla bidirectional, we add one stateless Lambda. It turns Linear webhooks (such as a QA Passed label being applied) and Slack commands (`/rollout`, `/rollout-pause`, `/rollout-abort`) into GitHub dispatches and PostHog API calls. All state lives in the systems people already look at:

- the Linear column and labels for a ticket
- the Linear Release stage for a Deployment
- GitHub for builds and runs
- PostHog for flag percentages

We rejected a release-conductor service with its own database. It would duplicate state that already exists in those tools, and someone would have to run it, with no DevOps resource available to do so. The router lives in signapse-core-terraform under the Bots product.

## Consequences

- Retries must be safe to repeat, because the router remembers nothing. Every action checks the current state in Linear, GitHub or PostHog before acting.
- The Slack `@release-clickers` group (the releasers) is the only group allowed to start, pause or abort a Rollout.
