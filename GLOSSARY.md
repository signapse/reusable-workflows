# Delivery Pipeline

How a Linear ticket's code travels from merge to every user: dev, staging, a dark prod deployment, then a flag rollout.

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
A production deployment of a Release Candidate whose Feature tickets' flags are off for everyone except the QA Cohort. QA does not have to act for it; a Releaser approves the production job.
_Avoid_: soft launch, "released"

**QA Cohort**:
The internal Signapse test users for which a feature flag is switched on in production, so the QA team can review a Dark Deployment, UI or API alike.

**Releasers**:
The people allowed to release today, and so to start, pause or abort a Rollout and to approve a production Terraform apply.
_Avoid_: release-clickers

**Rollout**:
Raising a feature flag in stages from the QA Cohort to every user, started by the QA team after their review. Not limited to the deploy window.

**Deploy window**:
The hours in which Promotion may run. It gates Promotion only, never a Rollout step.
_Avoid_: release (reserved for the Linear Release record), go-live

**Stability Window**:
The 24 hours after a Rollout reaches every user, during which Sentry's error rate decides whether the ticket is Done or the flag is turned back off. Without flag data from the service, a Releaser confirms Done instead.

## Tooling

**Prodzilla**:
The whole release bot: the release train that forms and promotes Release Candidates, plus the event router that carries Linear and Slack events into GitHub and PostHog.
_Avoid_: release bot, release train (that is only one part)

## Tickets

**QA Failed**:
A ticket whose change failed either human QA on dev or the automated suite on staging. Only the QA team takes a ticket out of QA Failed, by triaging it and assigning an engineer.

**Feature ticket**:
A ticket labelled Feature; it must ship behind its own feature flag. Bug and Improvement tickets go live on deployment and need no flag.
