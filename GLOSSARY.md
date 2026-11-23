# Delivery Pipeline

How a Linear ticket's code travels from pull request to every user: a merge authorised by its risk tier, then dev, staging, a dark prod deployment and a flag rollout.

## Promotion

**Release Candidate**:
The newest build of a repo on dev whose included tickets are all QA Passed. Promotion moves Release Candidates, never individual tickets; a ticket not yet QA Passed holds back every ticket merged after it.
_Avoid_: release branch, cherry-pick, "promoting a ticket"

**Promotion**:
Moving a Release Candidate to the next environment, triggered by a ticket reaching QA Passed rather than on a schedule.
_Avoid_: daily push, release run

**QA Passed**:
Ticket label applied by the QA team after reviewing the change on dev. Applying it is the event that triggers Promotion to staging.
_Avoid_: "Ready for Prod", a QA Passed column

**Staging Passed / Staging Failed**:
Ticket labels recording the automated suite's verdict on the Release Candidate that carried the ticket through staging. The only pipeline state kept in labels; everything else is a board column or a Linear Release stage.

## Production

**Deployment**:
A Release Candidate's image reaching production. The unit DORA counts for deployment frequency, lead time and change failure rate.
_Avoid_: counting tickets reaching Done as deployments

**Dark Deployment**:
A production deployment of a Release Candidate whose Feature tickets' flags are off for everyone except the QA Cohort. QA does not have to act for it; a Prod approver approves the production jobs.
_Avoid_: soft launch, "released"

**QA Cohort**:
The internal Signapse test users for which a feature flag is switched on in production, so the QA team can review a Dark Deployment, UI or API alike.

**Releasers**:
The people in the Slack `@release-clickers` group, the only ones allowed to start, pause or abort a Rollout. Not the Prod approvers.
_Avoid_: release-clickers

**Prod approvers**:
The GitHub team `prod-approvers`, the required reviewers on the `prod-apply` environment (prod Terraform applies) and the k8s `prod` environment (prod deploys). An automatic rollback runs in the `prod-rollback` environment and never waits for them.
_Avoid_: releasers team, `tech`

**Rollout**:
Raising a feature flag in stages from the QA Cohort to every user, started by the QA team after their review. Not limited to the deploy window. Aborting a Rollout turns the flag off: the code stays dark-deployed, the ticket goes back to On Prod and the Linear Release is not marked Rolled back (only a prod image rollback does that).

**Deploy window**:
The hours in which Promotion may run. It gates Promotion only, never a Rollout step.
_Avoid_: release (reserved for the Linear Release record), go-live

**Stability Window**:
The 24 hours after a Rollout reaches every user, during which Sentry's error rate decides whether the ticket is Done or the flag is turned back off. Without flag data from the service, the ticket stays in Rolling Out and Prodzilla asks the Releasers in Slack to confirm.

## Tooling

**Prodzilla**:
The whole release bot: the release train that forms and promotes Release Candidates, plus the event router that carries Linear and Slack events into GitHub and PostHog.
_Avoid_: release bot, release train (that is only one part)

## Merge

**Risk tier**:
Low, Medium or High: how much harm merging a pull request could do, which decides who must authorise the merge. Set by the Risk Check, never by the Writer.
_Avoid_: severity, risk score, risk level

**Standard change**:
A Low-tier pull request. The change-management procedure pre-authorises it, so the Risk Gate approves it and it merges once CI is green.
_Avoid_: auto-approved PR, trivial change

**Writer-authorised change**:
A Medium-tier pull request. It merges once the Writer has resolved every Risk Comment.

**Significant change**:
A High-tier pull request. It needs an approval from an engineer other than the Writer, who reads the Risk Comments rather than the whole diff.

**Writer**:
The engineer accountable for a pull request: its author or, for a factory pull request, the engineer who started the factory run.
_Avoid_: author (ambiguous for factory pull requests), owner

**Risk Check**:
The AI classification of a pull request, run by the Work Dashboard in a context separate from the agent or person who wrote it, against the Catalogue and Rubric on `main`. Its summary is the change's recorded impact assessment.
_Avoid_: risk review, risk audit (the audits are the factory's code and security reviews)

**Risk Gate**:
The GitHub Action, with no AI in it, that raises a Risk Check's tier to the Risk Floor, waits for CI, and approves as the Risk Bot when the tier allows.

**Risk Bot**:
The GitHub App identity the Risk Gate approves as. The only bot whose approval counts.
_Avoid_: CodeRabbit, which comments but never approves

**Risk Comment**:
A one-line inline comment on a single risky snippet, naming the system and what to check. At most five per pull request; tests, docs and Low-tier lines get none.

**Risk Floor**:
The lowest tier a pull request can get, fixed by the files it touches and what they contain, worked out without AI. The Risk Check may raise a tier above it, never lower it.

**Change kind**:
A category of change the Rubric scores, such as auth, money, data, contract, secret or config, dependency, infra or deploy, live-path behaviour, other behaviour, UI copy, or tests and docs.
_Avoid_: change type, category

**Catalogue**:
Signapse's systems, each with a system tier (1 critical, 2 important, 3 standard), its repos and paths, an owner and the reason for its tier.
_Avoid_: service list, inventory

**Rubric**:
The rules that turn a system tier and a kind of change into a Risk tier.

**Shadow mode**:
The Risk Check posts its tier and Risk Comments but approves nothing, so its ratings can be compared with engineers' before it is trusted.

**Emergency merge**:
A merge without the authorisation its tier needs, allowed only under the emergency procedure and reviewed afterwards.
_Avoid_: admin bypass

## Tickets

**QA Failed**:
A ticket whose change failed either human QA on dev or the automated suite on staging. Only the QA team takes a ticket out of QA Failed, by triaging it and assigning an engineer.

**Feature ticket**:
A ticket labelled Feature; it must ship behind its own feature flag. Bug and Improvement tickets go live on deployment and need no flag.
