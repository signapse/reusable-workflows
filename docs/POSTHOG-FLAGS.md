# PostHog feature flags: the standard setup

Every Feature ticket gets one PostHog flag, created by Prodzilla when the ticket moves to In Progress (SIG-2762). The flag is on for everyone in dev and staging, on for the QA Cohort only in prod (a Dark Deployment), and the QA team raises it from there in a Rollout (SIG-2768, SIG-2770). This page is the single definition of that flag. Code that creates or changes these flags must produce exactly what is written here.

Spec: ADR 0004 (`docs/adr/0004-dark-deployment-qa-owned-rollout.md`), architecture doc "PostHog", steps 1 and 8. Ticket: SIG-2749.

## The PostHog project

| | |
|---|---|
| Project | `SignStream Production`, id `256388`, EU cloud. This is the one project for all environments and all products. |
| Private API (flag create/update) | `https://eu.posthog.com/api/projects/256388/...`, personal API key with `feature_flag:read` and `feature_flag:write` |
| Public evaluation API (`/flags`) | `https://eu.i.posthog.com/flags?v=2`, project token (`phc_...`, public by design) |
| UI | `https://eu.posthog.com/project/256388/feature_flags` |

A second project, `SignStream Dev` (id `275880`), exists and sign-stream-platform and auth-service dev builds point at it. Flags created by Prodzilla live only in `256388`, so those dev builds will not see them until their dev token points at `256388` (see Gaps).

## Decision: aggregate by person, QA Cohort as a cohort, environment passed at evaluation time

A PostHog flag buckets either persons or one group type, never both, and cohorts only hold persons, so a group-aggregated flag cannot use a cohort. We use **person aggregation**:

1. **No group type exists in the project, and no app sends `$groups`.** A group-based flag would match nobody today.
2. **The QA Cohort can then be an ordinary cohort**, maintained by the QA team in the PostHog UI, and referenced by id from every flag. A group-based design would instead have to repeat a group-property condition in every flag.
3. **`environment` is a fact about the running deployment, not about the person.** Dev and prod share one project, so the same person (same distinct_id) can appear in more than one environment, and a stored person property would be last-write-wins. Apps therefore pass `environment` as a **person property override at evaluation time** (`setPersonPropertiesForFlags` in posthog-js, `personProperties` in server SDKs, `person_properties` on `/flags`). The `environment` super property apps already register is an *event* property and is not used by flag evaluation.

Consequence: the Rollout percentage counts users, not customer accounts. During 10% and 50%, two users of the same customer organisation can see different behaviour. If a product needs whole-account consistency later, see "Account-group variant" at the end.

## The template

`QA_COHORT_ID` is the numeric id of the QA Cohort (manual step 1 in SIG-2749). Body of `POST /api/projects/256388/feature_flags/`:

```json
{
  "key": "sig-<n>-<slug>",
  "name": "SIG-<n>: <ticket title> (<ticket url>). Created by Prodzilla; conditions follow reusable-workflows docs/POSTHOG-FLAGS.md, change only the last condition's percentage.",
  "active": true,
  "ensure_experience_continuity": false,
  "filters": {
    "aggregation_group_type_index": null,
    "multivariate": null,
    "payloads": {},
    "groups": [
      {
        "properties": [
          { "key": "environment", "type": "person", "operator": "exact", "value": ["dev", "development", "staging"] }
        ],
        "rollout_percentage": 100,
        "variant": null
      },
      {
        "properties": [
          { "key": "id", "type": "cohort", "operator": "in", "value": QA_COHORT_ID }
        ],
        "rollout_percentage": 100,
        "variant": null
      },
      {
        "properties": [
          { "key": "environment", "type": "person", "operator": "exact", "value": ["prod", "production"] }
        ],
        "rollout_percentage": 0,
        "variant": null
      }
    ]
  }
}
```

`actions/release-train/scripts/posthog-flag-payload.sh SIG-123 "<title>" [url]` (with `QA_COHORT_ID` set) prints this payload; its tests are `actions/release-train/test/posthog-flag.bats`. The Prodzilla event router is Go, so SIG-2762 ports it; keep the bats tests' expectations as the reference.

| Index | Condition | Percentage | Who changes it |
|---|---|---|---|
| `groups[0]` | `environment` is `dev`, `development` or `staging` | 100 | Nobody |
| `groups[1]` | person in the QA Cohort | 100 | Nobody |
| `groups[2]` | `environment` is `prod` or `production` | **the Rollout percentage**: 0, 10, 50, 100 | Prodzilla only |

Conditions are OR'd, so a person matching any condition gets the flag.

- **Every condition names its environment; there is no catch-all.** A non-cohort client whose `environment` override is missing or misspelt matches no condition, so it sees the flag dark (off) at every Rollout percentage, including 100. QA Cohort members still match `groups[1]` and see it. The cost: an app that does not pass `environment` never gets the feature for its non-cohort users. That is deliberate. The flag is removed from code after Done, so the feature does not stay hidden behind it.
- **`environment` must never be stored on a person.** When a request carries no override, PostHog falls back to stored person properties, so a stored `environment=prod` would put that person into the Rollout regardless of where the request came from. Apps must not send `environment` in `$set`, `$set_once`, `identify` properties or `setPersonProperties`; only the evaluation-time override and the event super property are allowed. Today no person in the project has a stored `environment` (checked 2026-11-03).
- `ensure_experience_continuity` is off: it is not needed for boolean flags with stable distinct_ids and it disables local evaluation.
- PostHog hashes flag key + distinct_id, so the people on at 10% stay on at 50% and 100%.

## Naming

`sig-<n>-<slug>`:

- `<n>` is the ticket number (`SIG-123` gives `sig-123`).
- `<slug>` is the ticket title with any leading `[Area]` tag removed, lowercased, every run of non-alphanumerics turned into `-`, trimmed of `-`, and cut to at most 40 characters at a `-` boundary (a single word longer than 40 is hard-cut).
- Example: SIG-2749 "[Platform] PostHog QA Cohort and environment-targeted flag template" gives `sig-2749-posthog-qa-cohort-and-environment`.

Titles change, so to find a ticket's flag match on the prefix `sig-<n>-`, never the full key: `GET /api/projects/256388/feature_flags/?search=sig-<n>-` and keep results whose `key` starts with `sig-<n>-`. That is also how SIG-2762 stays idempotent when a ticket returns to In Progress.

## Changing the Rollout percentage (SIG-2768, SIG-2770)

Only `groups[2].rollout_percentage` ever changes.

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

A **static** PostHog cohort named `QA Cohort`, description "Internal Signapse test accounts that see Feature flags in prod before a Rollout. Owned by the QA team. See reusable-workflows docs/POSTHOG-FLAGS.md."

Members are persons, identified by distinct_id, which is the account-service user id (a 24-character hex id, or a Google subject id for Google sign-in) with any `auth0` prefix (and its pipe separator) stripped. A person exists in PostHog only once that account has signed in to a PostHog-instrumented app in prod.

Why static rather than a filter (for example `email` contains `@signapse.ai`): no app sends email or name as person properties (sign-stream-platform deliberately does not, for consent reasons), so a property-based cohort has nothing to match.

Why not the existing `Internal / Test users` cohort (id `219508`): it is the project's analytics test-account filter, broader in intent (all staff), and today matches one local-development person. The QA Cohort is a narrower, QA-owned list.

**Maintaining members** (QA team):

- Add: PostHog, Persons, search the distinct_id, open the person, "Add to static cohort", `QA Cohort`. Or, on the cohort page, upload a CSV with a `distinct_id` column.
- Remove: open the cohort, remove the person.
- Who may be in it: only dedicated test accounts and Signapse staff accounts used for QA. Never a customer account. A change needs Lead QA's agreement; record it in #qa.
- Changes take effect on the next flag evaluation; no flag needs editing.

## What apps must send

For every product that checks a Feature flag:

| Field | Value | Where |
|---|---|---|
| distinct_id | account-service user id with the `auth0` prefix (and its pipe separator) stripped (sign-stream-platform's `posthog.identify(stripAuth0Prefix(user.user_id))` is the reference) | `identify` on the client; the same id on server checks |
| `environment` person property **for flags** | `dev`, `staging` or `prod` (canonical); `development` and `production` are accepted while existing apps still send them | client: `posthog.setPersonPropertiesForFlags({ environment })` straight after `posthog.init`; server: `personProperties` on every flag call |
| `environment` event super property | the same value | `posthog.register({ environment })` (already done in sign-stream-platform and auth-service) |
| project token | `256388`'s token in every environment | env file / config |

The account group (`groups: { account: <organisation id> }`) is not needed for targeting today. Sending it is harmless and useful for analytics; if a product does, use the group type name `account` so the variant below can be adopted without renaming.

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

`actions/release-train/scripts/posthog-flag-check.sh <flag-key>` evaluates the flag through `/flags` with `person_properties.environment` set, so it needs no app and writes nothing. It needs `POSTHOG_PROJECT_TOKEN` (project `256388`), `QA_DISTINCT_ID` (a QA Cohort member) and `OTHER_DISTINCT_ID` (an account outside it).

1. Create a test flag from the template (key `sig-2749-posthog-qa-cohort-and-environment`), prod condition at 0.
2. `PROD_PERCENT=0 posthog-flag-check.sh sig-2749-posthog-qa-cohort-and-environment`
   - AC2: on in `dev`, `development`, `staging` for both accounts; off in `prod` for the other account; 0 of 100 synthetic ids on.
   - AC3: on in `prod` (and `production`) for the QA account.
   - Fail dark: off for the other account and for every synthetic id with an empty or unknown `environment`.
3. Set `groups[2].rollout_percentage` to 10 (UI: the third condition set; or the PATCH above).
4. `PROD_PERCENT=10 posthog-flag-check.sh sig-2749-posthog-qa-cohort-and-environment`
   - AC4: about 10 of 100 synthetic non-cohort ids on (accepted 1 to 19, three standard deviations); QA account still on. The script refuses a `SAMPLE` too small for the band to exclude 0 and all.
5. Set it back to 0 and re-run step 2 (the abort path).
6. AC5: compare the flag's JSON in PostHog with the template above.

Synthetic ids (`sig-flag-check-<key>-<i>`) are only evaluated, never captured, so they create no persons.

## Account-group variant (not adopted)

If a product needs a Rollout to bucket customer organisations instead of users: create group type `account`, have the app send `groups: { account: <organisation id> }` on every evaluation, and use a flag with `aggregation_group_type_index` set to that type's index on every condition. The QA Cohort then cannot be a cohort; it becomes a group property (for example `qa_cohort = true`, set on the QA organisations) in `groups[1]`, and `environment` is passed as a group property override (`groupProperties`). Every flag of that product would use this variant, so decide per product before its first Feature flag.

## Gaps (as of 2026-11-03)

- **Only two apps use PostHog**: sign-stream-platform (SignStream portal) and signapse-auth-monorepo `auth-service`. sign-stream-api, hub-next, video-translation-platform and signapse-accounts have no PostHog SDK. Flags for their Feature tickets have nothing to read them until each repo adds the SDK as described above.
- **No app passes `environment` for flag evaluation yet.** Both apps register it as an event super property only, with values `production` / `development`. Until they call `setPersonPropertiesForFlags`, their users (dev and prod) see every Feature flag dark except QA Cohort members.
- **Dev builds use the separate `SignStream Dev` project (275880).** sign-stream-platform's `.env.development` (and auth-service) were moved there so dev and prod flags could differ; this template does that inside one project. Pointing dev at `256388` is a decision that reverses that change, so it belongs with the app-change tickets; until then, Prodzilla's flags are invisible on SignStream dev.
- **Rollout buckets users, not accounts** (see the decision above).
- **The project is named `SignStream Production`** although it is the all-environments, all-products project. Renaming it is optional and cosmetic.
