# GitHub Apps with short-lived tokens replace PATs; writes stay inside the owning repo

Pipeline jobs no longer use personal access tokens (`MACHINE_TOKEN`, `SIGNAPSE_CORE_K8S_PAT` and the like). Each job mints a one-hour installation token with `actions/create-github-app-token`, narrowed to the repos and permissions it needs. This follows the pattern signapse-core-k8s already uses with its Flux app.

Apps are split by risk:

- **Flux** (existing): writes signapse-core-k8s.
- **Modules**: read-only, covering the private Go module repos.
- **Pipeline read-only app**: `contents: read`, `pull-requests: read` and `actions: read` on the product repo (merged PRs, check runs, Terraform paths) and signapse-core-k8s (the image tags Flux committed). Release-train jobs that only read use it instead of borrowing Prodzilla's write permissions.
- **Prodzilla**: dispatches workflows, opens revert PRs and reads checks.

Narrowing each token's scope doesn't protect a leaked private key, which carries the app's full installation permissions. That is why the read-only apps are separate: a leak of a key that every repo holds can then only read, and Prodzilla's key stays limited to the workflows that dispatch or open PRs.

Cross-repo writes go through the owning repo's own workflow rather than a token from outside. The train dispatches `deploy-prod.yml`, `rollback.yml` and `terraform-deploy.yml`; each of those pushes with its own app or AWS role. The same pattern is used for Terraform in ADR 0002.

## Consequences

- An app's installation repo list is the allow-list. It is managed in Terraform, so adding a repo is a reviewed PR rather than an edit to a list in workflow YAML.
- Revert PRs must use the Prodzilla app. Pull requests opened with `GITHUB_TOKEN` don't trigger CI.
- The npm registry on GitHub Packages stays on `GITHUB_TOKEN` with per-package Actions access.
