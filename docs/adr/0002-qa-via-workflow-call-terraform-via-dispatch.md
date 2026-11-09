# Product pipelines call QA as a reusable workflow but trigger Terraform by dispatch

Both are gates a product pipeline must pass. We still integrate them differently on purpose:

- **signapse-e2e** is called as a `workflow_call` reusable workflow. The result comes back as a job in the caller's own run, which gives a synchronous pass/fail gate with no correlation or polling. Test URLs and credentials move to org-level GitHub environments or are passed as inputs.
- **signapse-core-terraform** is triggered by dispatch, and the pipeline waits for the run to finish. This keeps the AWS OIDC trust and apply credentials inside the Terraform repo; a product repo must never be able to assume the Terraform role.

Before Promotion to each environment, the pipeline plans the product's stack (taken from the repo's `.signapse/pipeline.yml`). In dev and staging it applies and continues whatever the plan, reporting replacements in its verdict. In prod, no diff or only new and changed resources: it applies after approval; a destroy or replace blocks and alerts. Infrastructure therefore always reaches an environment before the code that needs it. An unapplied Terraform change carrying a ticket's ID blocks that ticket's Promotion.

## Consequences

- Terraform needs `workflow_dispatch` inputs per product and environment, and change detection for stg and prod. Today those environments apply every product.
- Image tags are owned only by the pipeline. Terraform stops pinning app images, and `:latest` is never used in stg or prod.

## Decisions 2026-11-09

Terraform gate policy (Decision 19, Alex) replaces "a destroy or replace blocks" for every environment:

- **dev and staging** do not block on resource replacements or destroys. The apply proceeds and the verdict (`no_changes | safe | blocked | failed`) is still reported.
- **prod** blocks on replacements and destroys, and **every prod apply waits for approval** through a GitHub environment with required reviewers. The reviewers are the Releasers, the group that can release today through the existing release pipelines and Slack release button (Decision 16). The same group approves k8s `deploy-prod`.
- SageMaker stacks are applied in prod only after a human review for now (Decision 7).
