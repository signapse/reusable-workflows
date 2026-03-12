# CI/CD Pipeline Assessment & Target Proposal

**Date:** March 2026
**Scope:** All Lambda functions deployed in eu-west-2
**AWS Accounts:** Dev (887333319954), Prod (430916267664), ECR (827204657141)

---

## 1. Repos & Services Included

### 1.1 Go Lambda Services (S3 zip deployment)

| Repo | Lambda Functions | CI/CD Status |
|------|-----------------|-------------|
| feedback-api | feedback-api, feedback-event-dispatcher | Full CI/CD (existing) |
| hubspot-connector | hubspot-connector-events-listener | Full CI/CD (existing) |
| hub-platform-api | hub-platform-api | Full CI/CD (existing) |
| system-events | system-events-api, system-events-consumer | Full CI/CD (existing) |
| templates-api | templates-api | Full CI/CD (existing) |
| authorizer-auth0-rest | authorizer-auth0-rest | Full CI/CD (existing) |
| translation-service-api | translation-service-api, translation-event-consumer, translation-event-dispatcher | Full CI/CD (existing) |
| billing-service-api | billing-service-api, billing-event-dispatcher | PR open (CI-CD-pipeline branch) |
| account-service-api | accounts-service-api, accounts-event-dispatcher | PR open (CI-CD-pipeline branch) |
| connect | connect-api, connect-initiator, connect-kaltura-completer, connect-kaltura-sync, connect-s3-completer, connect-s3-sync, connect-status-checker | PR open (CI-CD-pipeline branch) |
| dev-portal-api | dev-portal-api | PR open (CI-CD-pipeline branch) |
| csv-processor | csv-processor | PR open (CI-CD-pipeline branch) |
| chat-api | sign-ai-chat | PR open (CI-CD-pipeline branch) |
| subtitle-generation-api | subtitle-generation-api | No CI/CD — Lambda doesn't exist in AWS yet |

### 1.2 Docker/ECR Lambda Services

| Repo | Lambda Function | ECR Repository | CI/CD Status |
|------|----------------|---------------|-------------|
| translation-platform-api | translation-platform-api | translation-platform-api | Full CI/CD (existing) |
| subtitle-generation | subtitle-generation | subtitle-generator | PR open (CI-CD-pipeline branch) |
| gloss-assets-manager-lambda | gloss-assets-manager | gloss-assets-manager | PR open (CI-CD-pipeline branch) |
| meter-processing | meter-processing | meter-processing | PR open (CI-CD-pipeline branch) |
| paragraph-generator | paragraph-generation | paragraph-generator | PR open (CI-CD-pipeline branch) |
| draft-video-generator | draft-video-generator | draft-video-generator | PR open (CI-CD-pipeline branch) |
| train-announcements | train-announcements-api, train-announcements-queue-processor, train-announcements-videos | No CI/CD — deferred |

### 1.3 Rust Lambda Services (no reusable workflow exists)

| Repo | Lambda Function | CI/CD Status |
|------|----------------|-------------|
| paragraph-translation-generate-lambda | paragraph-translation-generate | No CI/CD |
| bulk-gloss-suggest-lambda | bulk-gloss-suggest | No CI/CD |
| bulk-edit-gloss-lambda | (unknown) | No CI/CD |
| gloss-to-video-processor | gloss-to-video-processor | No CI/CD |

### 1.4 Kotlin Lambda Services (no reusable workflow exists)

| Repo | Lambda Function | CI/CD Status |
|------|----------------|-------------|
| ai-translation-lambda | ai-translation-flow | No CI/CD |

### 1.5 Other / Unknown Lambda Functions

| Lambda Function | Deployment Method | Notes |
|----------------|------------------|-------|
| thumbnail-generation | S3 zip (not Docker) | Needs build-and-deploy-lambda workflow |
| web-translations-config | Octopus Deploy | Different deployment model |
| keep-alive | Unknown | Unknown repo |
| gloss-video | Unknown | Unknown repo |
| user-portal | Unknown | Unknown repo |
| text-to-video | Unknown | Unknown repo |
| text-to-video-websocket | Unknown | Unknown repo |
| signstream-v2-websocket | Unknown | Unknown repo |
| translation-migrator | Unknown | Unknown repo |
| translation-platform-asset-generator | Unknown | Unknown repo |
| translation-platform-generated-consumer | Unknown | Unknown repo |
| translation-service-websocket | Unknown | Unknown repo |
| kaltura-connect-eu-west-2-initiator | Legacy naming | May be a duplicate of connect-initiator |
| s3-sync (prod only) | Unknown | Only exists in prod |

---

## 2. Current Pipeline (As-Is)

### 2.1 CI Steps

| Language | CI Approach | Reusable Workflow |
|----------|-----------|-------------------|
| Go | Lint (golangci-lint), format check, tests with coverage, Trivy security scan | `go-ci.yml` |
| Python (Docker repos) | Inline in `main.yml` — pip install + unittest | None (inline) |
| Rust | None | None |
| Kotlin | None | None |

### 2.2 CD Steps — Go Lambda (S3 zip)

```
Release published (GitHub) ──► go-lambda-deploy.yml ──► Build Go binary
                                                      ──► Zip to S3 bucket
                                                      ──► Update Lambda function code
```

- **Dev trigger:** `on: release: published` + `workflow_dispatch`
- **Prod trigger:** `workflow_dispatch` only (requires version input)
- **Reusable workflow:** `go-lambda-deploy.yml`
- **Artifacts:** Zip uploaded to S3 bucket (`dev-global-lambda-s3` / `production-global-lambda-s3`)

### 2.3 CD Steps — Docker/ECR Lambda

```
Release published (GitHub) ──► build-and-push-ecr.yml ──► Build Docker image
                                                        ──► Push to ECR (tag: release version)
                              ──► deploy-docker-image.yml ──► Update Lambda with new image URI
```

- **Dev trigger:** `on: release: published`
- **Prod trigger:** `workflow_dispatch` only (requires version input)
- **Reusable workflows:** `build-and-push-ecr.yml` + `deploy-docker-image.yml`
- **Artifacts:** Docker images in ECR (`827204657141.dkr.ecr.eu-west-2.amazonaws.com`)

### 2.4 Legacy Deployment (being phased out)

Some repos still use **Octopus Deploy** for deployment after ECR push:
- subtitle-generation (removed in PR)
- draft-video-generator (removed in PR)
- web-translations-config (still active)
- train-announcements (still active)

---

## 3. Environments & Promotion Flow

### 3.1 Current Environments

| Environment | AWS Account | S3 Bucket | IAM Role |
|------------|-------------|-----------|----------|
| Dev | 887333319954 | dev-global-lambda-s3 | arn:aws:iam::887333319954:role/github-access |
| Prod | 430916267664 | production-global-lambda-s3 | arn:aws:iam::430916267664:role/github-access |
| ECR (shared) | 827204657141 | — | arn:aws:iam::827204657141:role/github-actions-connect |

### 3.2 Current Promotion Flow

```
Code merged to main
       │
       ▼
GitHub Release created (tag: v1.x.x)
       │
       ▼
Dev deploy (automatic on release)
       │
       ▼
Manual verification in dev
       │
       ▼
Prod deploy (manual workflow_dispatch with version number)
```

### 3.3 Gap: No staging environment

There is no staging/UAT environment between dev and prod. Deployments go directly from dev to production after manual verification.

---

## 4. Secrets Management

### 4.1 Current Approach

All secrets stored as **GitHub repository secrets**, set per-repo.

| Secret | Purpose | Repos |
|--------|---------|-------|
| `HUB_PLATFORM_API_PAT` | Fine-grained GitHub PAT for accessing private Go modules (`service-contracts`, `backend-auth0`) | billing-service-api, account-service-api, hub-platform-api, translation-service-api, system-events, hubspot-connector |
| `LAMBDA_NAME_DEV` | Dev Lambda function name for Docker deploy | subtitle-generation, gloss-assets-manager-lambda, meter-processing, paragraph-generator, draft-video-generator |
| `LAMBDA_NAME_PROD` | Prod Lambda function name for Docker deploy | subtitle-generation, gloss-assets-manager-lambda, meter-processing, paragraph-generator, draft-video-generator |
| `OCTOPUS_URL` / `OCTOPUS_API_KEY` | Octopus Deploy credentials (legacy) | web-translations-config, train-announcements |

### 4.2 PAT Details

- **Type:** Fine-grained personal access token
- **Resource owner:** signapse organisation
- **Repository access:** service-contracts, backend-auth0, account-service-api, translation-service-api
- **Permission:** Contents: Read-only
- **Risk:** Token is tied to a personal account, not a machine user. Expiry requires manual rotation across all repos.

### 4.3 Gaps

- No organisation-level secrets — each repo has secrets configured individually
- PAT is a fine-grained token that expires and cannot be renewed without changing the value
- No automated secret rotation
- Lambda function names are hardcoded as secrets rather than derived from convention

---

## 5. Artifact Strategy

### 5.1 Go Lambda Artifacts

- Built as Linux AMD64 binaries (`GOOS=linux GOARCH=amd64`)
- Zipped and uploaded to S3 with a consistent key pattern: `<function-name>/function-<function-name>.zip`
- S3 bucket per environment (dev/prod)
- No versioning on S3 objects — each deploy overwrites the previous zip

### 5.2 Docker/ECR Artifacts

- Built and pushed to ECR in account 827204657141 (shared across environments)
- Tagged with: `latest` and the release tag (e.g., `v1.0.0`)
- Same image promoted from dev to prod (same ECR, different Lambda)

### 5.3 Gaps

- S3 zips are overwritten on each deploy — no way to roll back to a previous version without rebuilding
- No artifact checksums or signing
- `latest` tag on Docker images is mutable — not ideal for production traceability

---

## 6. Approval Gates & Release Versioning

### 6.1 Current Approach

- **Dev:** Automatic on release publish — no approval gate
- **Prod:** Manual `workflow_dispatch` — operator must enter the version tag
- **Versioning:** GitHub releases with semantic version tags (e.g., v1.0.0)
- **No branch protection rules enforcing PR reviews** (not verified — may vary per repo)

### 6.2 Gaps

- No GitHub Environment protection rules (no required reviewers for prod deploys)
- No deployment logs or audit trail beyond GitHub Actions run history
- No automated checks before prod deploy (e.g., "has this version been deployed to dev first?")

---

## 7. Rollback Approach

### 7.1 Current Approach

- **Go Lambda:** Re-run the `deploy-prod.yml` workflow with the previous version tag. This rebuilds from the git tag and redeploys.
- **Docker Lambda:** Re-run `deploy-prod.yml` with the previous version tag. The old image still exists in ECR (tagged), so no rebuild needed.
- **No automated rollback** — all rollbacks are manual.

### 7.2 Gaps

- No one-click rollback mechanism
- Go Lambda rollback requires a full rebuild from source (S3 zips are overwritten)
- No rollback runbooks or documented procedures
- No health checks or automatic rollback on deployment failure
- translation-platform-api has a `rollback.yml` workflow — this pattern could be standardised

---

## 8. Observability Hooks

### 8.1 Current Approach

- No deployment notifications (Slack, email, etc.)
- No deployment tracking in external systems
- No smoke tests post-deployment
- GitHub Actions provides run logs only

### 8.2 Gaps

- No Slack/Teams notification on deploy success/failure
- No deployment events sent to monitoring (Datadog, CloudWatch, etc.)
- No post-deploy health checks
- No deployment frequency or lead time tracking

---

## 9. Reusable Workflows Inventory

Current workflows available in `signapse/reusable-workflows`:

| Workflow | Purpose | Used by |
|----------|---------|---------|
| `go-ci.yml` | Go CI — lint, test, coverage, security scan | Go Lambda repos |
| `go-lambda-deploy.yml` | Build Go binary, zip, upload to S3, update Lambda | Go Lambda repos |
| `build-and-push-ecr.yml` | Build Docker image, push to ECR | Docker Lambda repos |
| `deploy-docker-image.yml` | Update Lambda/ECS with new Docker image | Docker Lambda repos |
| `deploy-eks-helm.yml` | Deploy to EKS via Helm | EKS services |
| `super-lint.yml` | Super-Linter | General |
| `docker-lint.yml` | Dockerfile linting | Docker repos |
| `frontend-ci.yml` | Frontend CI (Node.js) | Frontend repos |
| `ci.yml` | Combined CI (super-linter + frontend) | Frontend repos |
| `Python-lint.yml` | Python linting | Not widely used |
| `python-unit-testing-workflow.yml` | Python unit tests | Not widely used |
| `security-workflow.yml` | Security scanning | General |
| `kotlin-linting-workflow.yml` | Kotlin linting | Not used |
| `kotlin-unit-test.yml` | Kotlin unit tests | Not used |
| `javascript-lint.yml` | JavaScript linting | Not widely used |
| `javascript-test-workflow.yml` | JavaScript tests | Not widely used |
| `build-and-deploy-lambda.yml` | Build and deploy Lambda (combined) | Not widely used |

### Missing Reusable Workflows

| Needed | For | Priority |
|--------|-----|----------|
| `rust-ci.yml` | Rust Lambda repos (4 repos) | High |
| `rust-lambda-deploy.yml` | Rust Lambda deployment | High |
| `kotlin-ci.yml` (combined) | Kotlin Lambda repo | Medium |
| `kotlin-lambda-deploy.yml` | Kotlin Lambda deployment | Medium |
| `python-ci.yml` (combined) | Python Docker repos CI standardisation | Low |

---

## 10. Target Pipeline Proposal (To-Be)

### 10.1 Standardised Pipeline Structure

Every repo should have three workflow files:

```
.github/workflows/
  ci.yml          ── Runs on PR + push to main
  deploy-dev.yml  ── Runs on release publish + workflow_dispatch
  deploy-prod.yml ── Runs on workflow_dispatch only (version input required)
```

### 10.2 CI Standard (per language)

| Language | Reusable Workflow | Steps |
|----------|-------------------|-------|
| Go | `go-ci.yml` | Lint, format, test + coverage, Trivy scan |
| Python | `python-ci.yml` (to build) | Lint, unittest, Trivy scan |
| Rust | `rust-ci.yml` (to build) | Clippy, fmt, test, Trivy scan |
| Kotlin | `kotlin-ci.yml` (to build) | Ktlint, unit tests, Trivy scan |

### 10.3 CD Standard

**Go Lambda:**
```
ci.yml (PR) ──► merge ──► release tag ──► deploy-dev.yml (auto)
                                              │
                                              ▼
                                     deploy-prod.yml (manual, version input)
```

**Docker/ECR Lambda:**
```
ci.yml (PR) ──► merge ──► release tag ──► release.yml (build + push ECR + deploy dev)
                                              │
                                              ▼
                                     deploy-prod.yml (manual, version input, image already in ECR)
```

### 10.4 Recommended Improvements

#### Short-term (next sprint)

1. **Merge the 11 open PRs** to get current repos onto reusable workflows
2. **Add GitHub Environment protection rules** for prod — require at least 1 reviewer approval before prod deploy runs
3. **Add Slack notifications** to deploy workflows (success/failure)
4. **Create `rust-lambda-deploy.yml`** reusable workflow to cover the 4 Rust repos
5. **Investigate the "unknown" Lambdas** listed in Section 1.5 — map them to repos

#### Medium-term (next quarter)

6. **Move PAT to a GitHub App or machine user** — eliminates personal token expiry risk
7. **Add organisation-level secrets** for shared values (AWS role ARNs, PATs) instead of per-repo
8. **Enable S3 versioning** on Lambda S3 buckets — allows instant rollback without rebuild
9. **Standardise a `rollback.yml`** workflow (based on translation-platform-api's pattern)
10. **Add post-deploy smoke tests** — a simple health check Lambda invocation after deploy
11. **Create a staging environment** between dev and prod

#### Long-term

12. **Deployment dashboard** — track deploy frequency, lead time, failure rate (DORA metrics)
13. **Automated canary deployments** using Lambda aliases and weighted traffic shifting
14. **Artifact signing** for Docker images and S3 zips
15. **GitOps approach** — declarative deployment manifests for Lambda configuration

### 10.5 Naming Conventions (proposed standard)

```
Lambda function:  {env}-{service-name}-lambda
S3 key:           {service-name}/function-{service-name}.zip
ECR repo:         {service-name}
GitHub workflow:   ci.yml, deploy-dev.yml, deploy-prod.yml, release.yml
Branch:           main (default), CI-CD-pipeline (workflow changes)
Release tag:      v{major}.{minor}.{patch} (semver)
```

---

## 11. Summary

| Metric | Count |
|--------|-------|
| Total Lambda functions (dev) | 52 |
| Full CI/CD (before this work) | 12 |
| CI/CD added (PRs open) | 19 |
| Remaining without CI/CD | ~21 |
| Rust (needs reusable workflow) | 4 |
| Kotlin (needs reusable workflow) | 1 |
| Train announcements (deferred) | 3 |
| Unknown/unmapped | ~13 |
