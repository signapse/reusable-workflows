# Product pipelines call QA as a reusable workflow but trigger Terraform by dispatch

Both are gates a product pipeline must pass. We still integrate them differently on purpose:

- **signapse-e2e** is called as a `workflow_call` reusable workflow. The result comes back as a job in the caller's own run, which gives a synchronous pass/fail gate with no correlation or polling. Test URLs and credentials come from org-level variables and secrets, or are passed as inputs.
- **signapse-core-terraform** is triggered by dispatch, and the pipeline waits for the run to finish. This keeps the AWS OIDC trust and apply credentials inside the Terraform repo; a product repo must never be able to assume the Terraform role.

Before Promotion to each environment, the pipeline plans and applies the product's stack (taken from the repo's `.signapse/pipeline.yml`). What blocks depends on the environment, and the verdict (`no_changes | safe | blocked | failed`) is always reported:

- **dev** applies whatever the plan holds.
- **staging** applies everything except a destroy or replace of a stateful resource type (databases, buckets and the like, a short explicit list in signapse-core-terraform), which blocks.
- **prod** blocks on any destroy or replace, and every prod apply waits for approval in the `prod-apply` GitHub environment. Its required reviewers are the GitHub team `prod-approvers` (the Prod approvers), which also approves k8s prod deploys (the `prod` environment). Automatic rollbacks run in a separate `prod-rollback` environment with no reviewers, so they never wait.

Infrastructure therefore always reaches an environment before the code that needs it. An unapplied Terraform change carrying a ticket's ID blocks that ticket's Promotion.

## Consequences

- Terraform needs `workflow_dispatch` inputs per product and environment, and change detection for stg and prod. Today those environments apply every product.
- Image tags are owned only by the pipeline, and `:latest` is never used in stg or prod. Terraform stops pinning app images, except SageMaker endpoints (such as gloss-translation GPU): they stay pinned in Terraform and their prod apply is human-reviewed for now. A follow-up ticket covers a better SageMaker release process.
- Not yet decided: turning on "Prevent self-review" on `prod-apply`, so whoever triggers a prod apply cannot approve it.
