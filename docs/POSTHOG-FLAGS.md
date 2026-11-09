# PostHog feature flags: the standard setup

Every Feature ticket gets one PostHog flag key, created by Prodzilla when the ticket moves to In Progress (SIG-2762) in both PostHog projects. The flag is on for every user in dev and staging, on for the QA Cohort only in prod (a Dark Deployment), and the QA team raises it from there in a Rollout (SIG-2768, SIG-2770). This page is the single definition of that flag. Code that creates or changes these flags must produce exactly what is written here.

Spec: ADR 0004 "Dark Deployment, QA-owned Rollout" and the Autonomous Delivery Pipeline architecture doc ("PostHog", steps 1 and 8). Ticket: SIG-2749.

## The PostHog projects

Decision (Alex, 2026-11-09, decision 10): PostHog has **two** projects, both EU cloud, and Prodzilla creates each `sig-<n>-<slug>` flag with the **same key in both**.

| | Prod project | Dev project |
|---|---|---|
| Project | `SignStream Production`, id `256388` | `SignStream Dev`, id `275880` |
| Config name | `posthog_project_id_prod` | `posthog_project_id_dev` |
| The flag | the template below (dev/staging 100%, QA Cohort 100%, prod at the Rollout percentage) | on for everyone, 100% |
| QA Cohort | here (`qa_cohort_id` is a prod-project cohort id) | none |
| Rollout steps, `/rollout-pause`, `/rollout-abort`, the Sentry check, the release-train flag guard | act on / read this project only | never |
| Flag removal after Done | yes | yes |
| Private API (flag create/update) | `https://eu.posthog.com/api/projects/256388/...` | `https://eu.posthog.com/api/projects/275880/...` |
| UI | `https://eu.posthog.com/project/256388/feature_flags` | `https://eu.posthog.com/project/275880/feature_flags` |

Both use the personal API key scopes `feature_flag:read` and `feature_flag:write` for create/update (read only for the guards), and the public evaluation API `https://eu.i.posthog.com/flags?v=2` with the project's token (`phc_...`, public by design).

**Anything in this repo that reads or checks a flag reads the prod project** (`256388`): `posthog-flag-check.sh`, and the release-train AC5 flag guard (`feature-flag-guard.sh`, input `posthog_project_id_prod`). The dev project's copy is on for everyone and has nothing to guard.

sign-stream-platform and auth-service dev builds already point at the dev project, so they see every Feature flag on. Builds pointed at the prod project still pass `environment` (below): the prod template keeps dev and staging on for everyone through `groups[0]`.

## Decision: aggregate by person, QA Cohort as a cohort, environment passed at evaluation time

A PostHog flag buckets either persons or one group type, never both, and cohorts only hold persons, so a group-aggregated flag cannot use a cohort. We use **person aggregation**:

1. **No group type exists in the project, and no app sends `$groups`.** A group-based flag would match nobody today.
2. **The QA Cohort can then be an ordinary cohort**, maintained by the QA team in the PostHog UI, and referenced by id from every flag. A group-based design would instead have to repeat a group-property condition in every flag.
3. **`environment` is a fact about the running deployment, not about the person.** Staging and prod (and any dev build pointed at it) share the prod project, so the same person (same distinct_id) can appear in more than one environment, and a stored person property would be last-write-wins. Apps therefore pass `environment` as a **person property override at evaluation time** (`setPersonPropertiesForFlags` in posthog-js, `personProperties` in server SDKs, `person_properties` on `/flags`). The `environment` super property apps already register is an *event* property and is not used by flag evaluation.

Consequence (decision 9, Alex, 2026-11-09: flags target users, meaning PostHog persons): the Rollout percentage counts users, not customer accounts. During 10% and 50%, two users of the same customer organisation can see different behaviour. Whole-account consistency would need a group-aggregated flag, which cannot use a cohort; design it when a product needs it.

## The template

### Prod project (256388)

`QA_COHORT_ID` is the numeric id of the QA Cohort in the prod project (manual step 1 in SIG-2749). The body of `POST /api/projects/256388/feature_flags/` is what `actions/release-train/scripts/posthog-flag-payload.sh SIG-123 "<title>" [url]` prints with `QA_COHORT_ID` set: key `sig-<n>-<slug>` (see Naming), name `SIG-<n>: <ticket title> (<ticket url>). Created by Prodzilla; ...`, `active: true`, `ensure_experience_continuity: false`, person aggregation (`aggregation_group_type_index: null`), no variants, and these three conditions in this order:

| Index | Condition | Percentage | Who changes it |
|---|---|---|---|
| `groups[0]` | person property `environment` `exact` `["dev", "development", "staging"]` | 100 | Nobody |
| `groups[1]` | cohort `id` `in` `QA_COHORT_ID` | 100 | Nobody |
| `groups[2]` | person property `environment` `exact` `["prod", "production"]` | **the Rollout percentage**: 0, 10, 50, 100 | Prodzilla only |

**Which copy wins.** This page defines the flag. `posthog-flag-payload.sh` and its tests (`actions/release-train/test/posthog-flag.bats`) are the executable form of this section; if they ever disagree with this page, the page wins and the script is the bug. SIG-2762 ports the script to Go (the Prodzilla event router) and should port those test expectations with it.

Conditions are OR'd, so a user (PostHog person) matching any condition gets the flag.

- **Every condition names its environment; there is no catch-all.** A non-cohort client whose `environment` override is missing or misspelt matches no condition, so it sees the flag dark (off) at every Rollout percentage, including 100. QA Cohort members still match `groups[1]` and see it. The cost: an app that does not pass `environment` never gets the feature for its non-cohort users. That is deliberate. The flag is removed from code after Done, so the feature does not stay hidden behind it.
- **`environment` must never be stored on a person.** When a request carries no override, PostHog falls back to stored person properties, so a stored `environment=prod` would put that person into the Rollout regardless of where the request came from. Apps must not send `environment` in `$set`, `$set_once`, `identify` properties or `setPersonProperties`; only the evaluation-time override and the event super property are allowed. Today no person in the project has a stored `environment` (checked 2026-11-03).
- `ensure_experience_continuity` is off: it is not needed for boolean flags with stable distinct_ids and it disables local evaluation.
- PostHog hashes flag key + distinct_id, so the users on at 10% stay on at 50% and 100%.

### Dev project (275880)

The body of `POST /api/projects/275880/feature_flags/` is what `POSTHOG_PROJECT=dev posthog-flag-payload.sh SIG-123 "<title>" [url]` prints (no `QA_COHORT_ID` needed): the same key and name, person aggregation, and one condition with no properties at 100%. It is on for everyone in dev and never changes until the flag is removed.

## Naming

`sig-<n>-<slug>`:

- `<n>` is the ticket number (`SIG-123` gives `sig-123`).
- `<slug>` is the ticket title with any leading `[Area]` tag removed, lowercased, every run of non-alphanumerics turned into `-`, trimmed of `-`, and cut to at most 40 characters at a `-` boundary (a single word longer than 40 is hard-cut).
- Example: SIG-2749 "[Platform] PostHog QA Cohort and environment-targeted flag template" gives `sig-2749-posthog-qa-cohort-and-environment`.

Titles change, so to find a ticket's flag match on the prefix `sig-<n>-`, never the full key: `GET /api/projects/<project>/feature_flags/?search=sig-<n>-` and keep results whose `key` starts with `sig-<n>-`. That is also how SIG-2762 stays idempotent when a ticket returns to In Progress: it looks in each project and creates only what is missing. Removal after Done deletes the flag from both projects; everything else reads or writes the prod project only.

## Changing the Rollout percentage (SIG-2768, SIG-2770)

Only the prod project's (`256388`) flag changes, and only its `groups[2].rollout_percentage`. The dev project's copy is never touched by a Rollout, pause or abort.

1. `GET /api/projects/256388/feature_flags/<id>/`. Keep `version`.
2. Check the flag still has the template shape: three groups; `groups[0]` is the `environment` condition at 100; `groups[1]` is the cohort condition for `QA_COHORT_ID` at 100; `groups[2]` is the `environment` in `prod`/`production` condition. If not, someone edited it by hand: stop and alert Slack rather than writing.
3. `PATCH` the flag with `filters` equal to what you read with only `groups[2].rollout_percentage` changed, and the `version` from step 1. PostHog answers 409 if anyone changed the flag since your read; re-read and re-check, never blind-retry.

| Action | `groups[2].rollout_percentage` |
|---|---|
| Created (Dark Deployment) | 0 |
| `/rollout` steps | 10, then 50, then 100 |
| `/rollout-pause` | unchanged |
| `/rollout-abort`, or the Sentry check stops the Rollout | 0, which is QA Cohort only in prod; dev and staging stay on |

Because abort only touches `groups[2]`, it can never switch the flag off for the QA Cohort or for dev and staging.

## The QA Cohort

A **static** PostHog cohort in the prod project (`256388`) named `QA Cohort`, description "Internal Signapse test users that see Feature flags in prod before a Rollout. Owned by the QA team. See reusable-workflows docs/POSTHOG-FLAGS.md."

Members are persons, identified by distinct_id, which is the account-service user id (a 24-character hex id, or a Google subject id for Google sign-in) with any `auth0` prefix (and its pipe separator) stripped. A person exists in PostHog only once that user has signed in to a PostHog-instrumented app in prod.

Why static rather than a filter (for example `email` contains `@signapse.ai`): no app sends email or name as person properties (sign-stream-platform deliberately does not, for consent reasons), so a property-based cohort has nothing to match.

Why not the existing `Internal / Test users` cohort (id `219508`): it is the project's analytics test-account filter, broader in intent (all staff), and today matches one local-development person. The QA Cohort is a narrower, QA-owned list.

**Maintaining members** (QA team):

- Add: PostHog, Persons, search the distinct_id, open the person, "Add to static cohort", `QA Cohort`. Or, on the cohort page, upload a CSV with a `distinct_id` column.
- Remove: open the cohort, remove the person.
- Who may be in it: only dedicated test users and Signapse staff users used for QA. Never a customer's user. A change needs Lead QA's agreement; record it in #qa.
- Changes take effect on the next flag evaluation; no flag needs editing.

## What apps must send

For every product that checks a Feature flag:

| Field | Value | Where |
|---|---|---|
| distinct_id | account-service user id with the `auth0` prefix (and its pipe separator) stripped (sign-stream-platform's `posthog.identify(stripAuth0Prefix(user.user_id))` is the reference) | `identify` on the client; the same id on server checks |
| `environment` person property **for flags** | `dev`, `staging` or `prod` (canonical); `development` and `production` are accepted while existing apps still send them | client: `posthog.setPersonPropertiesForFlags({ environment })` straight after `posthog.init`; server: `personProperties` on every flag call |
| `environment` event super property | the same value | `posthog.register({ environment })` (already done in sign-stream-platform and auth-service) |
| project token | prod and staging: `256388`'s token; dev: `275880`'s token (or `256388`'s, where `groups[0]` keeps it on) | env file / config |

The account group (`groups: { account: <organisation id> }`) is not needed for targeting today. Sending it is harmless and useful for analytics; if a product does, use the group type name `account`.

posthog-js example:

```ts
posthog.init(token, { api_host: "/ingest", defaults: "2026-01-30" });
posthog.register({ environment: APP_ENV });                // events
posthog.setPersonPropertiesForFlags({ environment: APP_ENV }); // flag evaluation, reloads flags
```

## Go services (server-side checks)

Use `github.com/posthog/posthog-go`. Pass the same distinct_id the frontend identifies with and the environment on every call:

```go
client, _ := posthog.NewWithConfig(os.Getenv("POSTHOG_PROJECT_TOKEN"), posthog.Config{
    Endpoint:       "https://eu.i.posthog.com",
    PersonalApiKey: os.Getenv("POSTHOG_FLAGS_SECURE_KEY"), // optional: enables local evaluation
})
defer client.Close()

res, err := client.IsFeatureEnabled(posthog.FeatureFlagPayload{
    Key:              "sig-123-some-feature",
    DistinctId:       userID, // account-service id, no auth0| prefix
    PersonProperties: posthog.NewProperties().Set("environment", env), // "dev" | "staging" | "prod"
})
// IsFeatureEnabled returns interface{}: a bool for boolean flags. An error or
// any non-bool result is treated as off (fail dark).
on, _ := res.(bool)
if err != nil {
    on = false
}
```

- With local evaluation, `groups[0]` and `groups[2]` are evaluated in-process. The QA Cohort condition cannot be (static cohorts are not shipped to SDKs), so the SDK falls back to a `/flags` request when the answer depends on it. Do not set `OnlyEvaluateLocally`, or QA Cohort members will read as off in prod.
- Treat errors and timeouts as off.
- Sentry feature-flag context (SIG-2770) needs the evaluated value recorded on the scope; that is per-repo work.

## Verifying a flag (SIG-2749 AC2 to AC4)

`actions/release-train/scripts/posthog-flag-check.sh <flag-key>` evaluates the flag through `/flags` with `person_properties.environment` set, so it needs no app and writes nothing. It reads the prod project only and needs `POSTHOG_PROJECT_TOKEN` (project `256388`), `QA_DISTINCT_ID` (a QA Cohort member) and `OTHER_DISTINCT_ID` (a user outside it).

1. Create a test flag from the template (key `sig-2749-posthog-qa-cohort-and-environment`) in the prod project, prod condition at 0, and the dev-project copy in `275880`.
2. `PROD_PERCENT=0 posthog-flag-check.sh sig-2749-posthog-qa-cohort-and-environment`
   - AC2: on in `dev`, `development`, `staging` for both users; off in `prod` and `production` for the other user; 0 of 100 synthetic ids on.
   - AC3: on in `prod` for the QA user.
   - Fail dark: off for the other user with an empty or unknown `environment`, and for every synthetic id with an unknown one.
3. Set `groups[2].rollout_percentage` to 10 (UI: the third condition set; or the PATCH above).
4. `PROD_PERCENT=10 posthog-flag-check.sh sig-2749-posthog-qa-cohort-and-environment`
   - AC4: about 10 of 100 synthetic non-cohort ids on (accepted 1 to 19, three standard deviations); QA user still on. Synthetic ids alternate between `prod` and `production`. The script refuses a `SAMPLE` too small for the band to exclude 0 and all.
5. Set it back to 0 and re-run step 2 (the abort path).
6. AC5: compare each project's flag JSON in PostHog with the output of `posthog-flag-payload.sh` (`POSTHOG_PROJECT=dev` for `275880`).

At 0% a flag missing `production` from `groups[2]` looks the same as a correct one (both are off). For the test flag, also run the check at `PROD_PERCENT=100`, where the other user must be on in both `prod` and `production`; for a real flag, step 6's comparison covers it.

Synthetic ids (`sig-flag-check-<key>-<i>`) are only evaluated, never captured, so they create no persons.

## Gaps (as of 2026-11-03)

- **Only two apps use PostHog**: sign-stream-platform (SignStream portal) and signapse-auth-monorepo `auth-service`. sign-stream-api, hub-next, video-translation-platform and signapse-accounts have no PostHog SDK. Flags for their Feature tickets have nothing to read them until each repo adds the SDK as described above.
- **No app passes `environment` for flag evaluation yet.** Both apps register it as an event super property only, with values `production` / `development`. Until they call `setPersonPropertiesForFlags`, their users on the prod project see every Feature flag dark except QA Cohort members.
- **Rollout buckets users, not accounts** (see the decision above).
- **The prod project is named `SignStream Production`** although it serves every product's staging and prod. Renaming it is optional and cosmetic.
