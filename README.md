# Reusable Workflows

Central repository for GitHub Actions reusable workflows across Signapse projects.

## Overview

This repository provides a shared foundation of reusable workflows that individual project repositories can call into. The workflows follow consistent naming conventions, versioning strategies, and input/output patterns to ensure maintainability and avoid breaking changes.

## Repository Structure

```
.github/workflows/
├── build-and-push-ecr.yml          # Build Docker images and push to ECR
├── deploy-docker-image.yml         # Deploy Docker images to AWS (Lambda/ECS/EKS)
└── super-lint.yml                  # Code linting with Super-Linter

examples/
├── hub-platform-deployment.yml                    # Hub Platform release workflow
├── hub-platform-deploy-prod.yml                   # Hub Platform production deployment
├── video-translation-platform-deployment.yml      # Video Translation release workflow
├── video-translation-platform-deploy-prod.yml     # Video Translation production deployment
├── text2gloss-deployment.yml                      # Text2Gloss Lambda deployment
├── deploy-dev.yml                                 # Generic dev deployment example
└── release.yml                                    # Generic release example
```

## Core Reusable Workflows

### 1. Build and Push to ECR (`build-and-push-ecr.yml`)

Builds Docker images and pushes them to Amazon ECR with configurable build arguments and tagging strategies.

**Purpose**: Standardize Docker image builds across all projects

**Inputs**:
- `ecr_repository_uri` (required): ECR repository URI
- `aws_region` (required): AWS region
- `iam_role_arn` (required): IAM role ARN for OIDC authentication
- `image_tag` (required): Docker image tag
- `docker_build_args` (optional): Multi-line Docker build arguments
- `dockerfile_path` (optional): Path to Dockerfile (default: `./Dockerfile`)
- `docker_context` (optional): Docker build context (default: `.`)
- `push_latest` (optional): Push `:latest` tag (default: `true`)

**Outputs/Artifacts**:
- `deploy_info-{image_tag}`: JSON artifact containing deployment metadata (image URIs, version, commit SHA, etc.)

**Usage Example**:
```yaml
jobs:
  build:
    uses: signapse/reusable-workflows/.github/workflows/build-and-push-ecr.yml@main
    with:
      ecr_repository_uri: "827204657141.dkr.ecr.eu-west-2.amazonaws.com/my-app"
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::827204657141:role/github-actions-connect"
      image_tag: development-${{ github.event.release.tag_name }}
      docker_build_args: |
        MODE=development
        NODE_ENV=production
      push_latest: false
    permissions:
      id-token: write
      contents: read
```

### 2. Deploy Docker Image (`deploy-docker-image.yml`)

Generic deployment workflow supporting Lambda, ECS, and EKS services.

**Purpose**: Provide a unified deployment interface across different AWS compute services

**Inputs**:
- `service_type` (required): Type of AWS service (`lambda`, `ecs`, `eks`)
- `image_uri` (required): Full Docker image URI including tag
- `aws_region` (required): AWS region
- `iam_role_arn` (required): IAM role ARN for OIDC authentication
- `service_name` (optional): Service/function name (can use input or secret)
- `cluster_name` (optional): ECS/EKS cluster name
- `namespace` (optional): Kubernetes namespace for EKS (default: `default`)
- `container_name` (optional): Container name in EKS deployment
- `wait_for_completion` (optional): Wait for deployment (default: `true`)

**Secrets**:
- `service_name_secret` (optional): Alternative to `service_name` input for sensitive names

**Usage Example (Lambda)**:
```yaml
jobs:
  deploy:
    uses: signapse/reusable-workflows/.github/workflows/deploy-docker-image.yml@main
    with:
      service_type: lambda
      image_uri: 827204657141.dkr.ecr.eu-west-2.amazonaws.com/my-app:v1.0.0
      aws_region: eu-west-2
      iam_role_arn: arn:aws:iam::887333319954:role/github-access
      wait_for_completion: true
    secrets:
      service_name_secret: ${{ secrets.LAMBDA_NAME_DEV }}
    permissions:
      id-token: write
      contents: read
```

**Usage Example (ECS)**:
```yaml
jobs:
  deploy:
    uses: signapse/reusable-workflows/.github/workflows/deploy-docker-image.yml@main
    with:
      service_type: ecs
      image_uri: 827204657141.dkr.ecr.eu-west-2.amazonaws.com/my-app:v1.0.0
      aws_region: eu-west-2
      iam_role_arn: arn:aws:iam::887333319954:role/github-access
      cluster_name: fargate-dev
      service_name: my-app-dev
      wait_for_completion: true
    permissions:
      id-token: write
      contents: read
```

### 3. Super Linter (`super-lint.yml`)

Code quality and linting workflow using GitHub Super-Linter.

**Purpose**: Enforce code quality standards across repositories

**Inputs**:
- `run-lint` (optional): Enable/disable linting (default: `true`)

**Usage Example**:
```yaml
jobs:
  lint:
    uses: signapse/reusable-workflows/.github/workflows/super-lint.yml@main
    with:
      run-lint: true
```

## Conventions

### Workflow Naming

- **Reusable workflows**: Use descriptive, action-oriented names (e.g., `build-and-push-ecr.yml`, `deploy-docker-image.yml`)
- **Caller workflows**: Use purpose-specific names (e.g., `release.yml`, `deploy-prod.yml`)

### Required Inputs

All reusable workflows follow these principles:
- **Required inputs** are explicitly marked with `required: true`
- **Optional inputs** have sensible defaults
- **Secrets** are passed via the `secrets:` section, never in `with:`
- **Descriptions** are clear and include examples where helpful

### Secrets Passing Pattern

GitHub Actions requires secrets to be passed explicitly to reusable workflows:

**❌ Incorrect**:
```yaml
with:
  service_name: ${{ secrets.LAMBDA_NAME }}  # Won't work
```

**✅ Correct**:
```yaml
with:
  service_type: lambda
secrets:
  service_name_secret: ${{ secrets.LAMBDA_NAME }}  # Correct
```

### Versioning & Pinning Strategy

#### For Reusable Workflows Repository

- Use **GitHub releases** with semantic versioning (e.g., `v1.0.0`, `v1.1.0`)
- Tag major versions (e.g., `v1`, `v2`) that auto-update to latest minor/patch
- Maintain a `main` branch for latest stable version

#### For Consuming Repositories

**Option 1: Pin to `main` (recommended for active development)**
```yaml
uses: signapse/reusable-workflows/.github/workflows/build-and-push-ecr.yml@main
```
- ✅ Always gets latest features and fixes
- ⚠️ May receive breaking changes

**Option 2: Pin to major version (recommended for production)**
```yaml
uses: signapse/reusable-workflows/.github/workflows/build-and-push-ecr.yml@v1
```
- ✅ Receives bug fixes and minor updates
- ✅ Protected from breaking changes
- ⚠️ Requires manual update for major versions

**Option 3: Pin to specific version (maximum stability)**
```yaml
uses: signapse/reusable-workflows/.github/workflows/build-and-push-ecr.yml@v1.2.3
```
- ✅ Completely predictable behavior
- ✅ No unexpected changes
- ⚠️ Requires manual updates for all changes

**Current Status**: All examples use `@main` for rapid iteration. Update to versioned tags once workflows stabilize.

### Gradual Opt-In Strategy

Repositories can adopt reusable workflows incrementally:

1. **Start with build workflows**: Migrate Docker builds to `build-and-push-ecr.yml`
2. **Add deployments**: Use `deploy-docker-image.yml` for one environment (e.g., dev)
3. **Expand coverage**: Add staging/production deployments
4. **Add quality gates**: Integrate `super-lint.yml` and other checks

No "big bang" migration required - repos can adopt at their own pace.

## Standard Workflow Patterns

### Pattern 1: Multi-Environment Docker Builds

Build separate Docker images for development, staging, and production environments:

```yaml
name: Release

on:
  release:
    types: [published]

permissions:
  id-token: write
  contents: read

jobs:
  docker-lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hadolint/hadolint-action@v3.1.0
        with:
          dockerfile: Dockerfile

  build-development:
    needs: docker-lint
    uses: signapse/reusable-workflows/.github/workflows/build-and-push-ecr.yml@main
    with:
      ecr_repository_uri: "827204657141.dkr.ecr.eu-west-2.amazonaws.com/my-app"
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::827204657141:role/github-actions-connect"
      image_tag: development-${{ github.event.release.tag_name }}
      docker_build_args: |
        MODE=development
      push_latest: false
    permissions:
      id-token: write
      contents: read

  build-staging:
    needs: docker-lint
    uses: signapse/reusable-workflows/.github/workflows/build-and-push-ecr.yml@main
    with:
      ecr_repository_uri: "827204657141.dkr.ecr.eu-west-2.amazonaws.com/my-app"
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::827204657141:role/github-actions-connect"
      image_tag: staging-${{ github.event.release.tag_name }}
      docker_build_args: |
        MODE=staging
      push_latest: false
    permissions:
      id-token: write
      contents: read

  build-production:
    needs: docker-lint
    uses: signapse/reusable-workflows/.github/workflows/build-and-push-ecr.yml@main
    with:
      ecr_repository_uri: "827204657141.dkr.ecr.eu-west-2.amazonaws.com/my-app"
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::827204657141:role/github-actions-connect"
      image_tag: production-${{ github.event.release.tag_name }}
      docker_build_args: |
        MODE=production
      push_latest: false
    permissions:
      id-token: write
      contents: read

  deploy-dev:
    needs: build-development
    runs-on: ubuntu-latest
    steps:
      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::887333319954:role/github-access
          aws-region: eu-west-2

      - name: Deploy to ECS
        run: |
          # ECS deployment logic here
```

### Pattern 2: Manual Production Deployment

Separate workflow for manual production deployments with approval gates:

```yaml
name: Deploy to Production

on:
  workflow_dispatch:
    inputs:
      version:
        description: 'Version to deploy'
        required: true
        type: string

permissions:
  id-token: write
  contents: read

jobs:
  deploy-production:
    runs-on: ubuntu-latest
    environment: production  # Requires manual approval in GitHub Settings
    steps:
      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::430916267664:role/github-access
          aws-region: eu-west-2

      - name: Deploy to ECS
        run: |
          # ECS deployment logic here
```

## AWS Infrastructure Requirements

### Account Structure

The workflows assume a multi-account AWS setup:

- **Account 827204657141 (Shared)**: ECR repository for Docker images
- **Account 887333319954 (Development)**: Development services (Lambda, ECS, EKS)
- **Account 430916267664 (Production)**: Production services

### Required IAM Roles

#### Build Role (in ECR account)

**Role Name**: `github-actions-connect`
**Account**: 827204657141
**Purpose**: Build and push Docker images to ECR

**Trust Policy**:
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::827204657141:oidc-provider/token.actions.githubusercontent.com"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
                },
                "StringLike": {
                    "token.actions.githubusercontent.com:sub": "repo:signapse/*"
                }
            }
        }
    ]
}
```

**Permissions**: ECR push access

#### Deployment Role (in service accounts)

**Role Name**: `github-access`
**Accounts**: 887333319954 (dev), 430916267664 (prod)
**Purpose**: Deploy to Lambda/ECS/EKS services

**Trust Policy** (same structure, different account):
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::{ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
                },
                "StringLike": {
                    "token.actions.githubusercontent.com:sub": "repo:signapse/*"
                }
            }
        }
    ]
}
```

**Permissions**: ECS, Lambda, IAM PassRole

### OIDC Provider Setup

Each AWS account must have the GitHub OIDC provider configured:

1. Go to IAM → Identity providers → Add provider
2. Select **OpenID Connect**
3. **Provider URL**: `https://token.actions.githubusercontent.com`
4. **Audience**: `sts.amazonaws.com`
5. Click **Add provider**

## Security Best Practices

### 1. OIDC Authentication

All workflows use **OpenID Connect (OIDC)** for AWS authentication instead of long-lived access keys:
- ✅ No secrets to rotate
- ✅ Short-lived credentials
- ✅ Fine-grained access control via IAM conditions

### 2. Least Privilege Permissions

Workflows request only the minimum required permissions:
```yaml
permissions:
  id-token: write    # Required for OIDC
  contents: read     # Required for checkout
```

### 3. Secrets Management

- Service names can be stored as GitHub secrets
- Secrets are passed explicitly to reusable workflows
- Never expose secrets in logs

### 4. Manual Approval for Production

Production deployments use GitHub Environments with required reviewers:
```yaml
environment: production  # Requires approval in repo settings
```

## Artifact Upload Pattern

All build workflows upload a `deploy_info-{tag}` artifact containing deployment metadata:

**Artifact Contents** (`deploy_info.json`):
```json
{
  "image_uri_latest": "827204657141.dkr.ecr.eu-west-2.amazonaws.com/my-app:latest",
  "image_uri_release": "827204657141.dkr.ecr.eu-west-2.amazonaws.com/my-app:development-1.1.54",
  "version": "development-1.1.54",
  "commit_sha": "96b3d7202da49dc8d4dc3b64a4d8f472bdfe3c74",
  "repository": "signapse/my-app",
  "workflow_run_id": "20991174082",
  "workflow_run_number": "139",
  "actor": "username",
  "timestamp": "2026-01-14T10:44:28Z"
}
```

**Retention**: 90 days

**Purpose**:
- Audit trail of deployments
- Traceability between code and deployed images
- Input for downstream processes

## Examples

See the `examples/` directory for complete working examples:

- **Hub Platform**: Multi-environment ECS deployment with automatic dev deployment
- **Video Translation Platform**: Multi-environment ECS deployment
- **Text2Gloss**: Lambda deployment with dev/prod stages
- **Generic Examples**: Reference implementations for common patterns

## Migration Guide

### Migrating from Custom Workflows

1. **Identify current workflow steps**:
   - Docker build steps → `build-and-push-ecr.yml`
   - AWS deployments → `deploy-docker-image.yml`
   - Linting → `super-lint.yml`

2. **Update IAM roles**:
   - Ensure OIDC provider exists in all accounts
   - Update IAM role trust policies
   - Verify permissions

3. **Create caller workflow**:
   - Copy relevant example from `examples/`
   - Update ECR URIs, regions, IAM roles
   - Test in development first

4. **Test and iterate**:
   - Run workflow on a test branch
   - Verify artifacts are created
   - Confirm deployments succeed

5. **Update pinning strategy** (optional):
   - Pin to `@main` initially
   - Switch to version tags once stable

## Troubleshooting

### Common Issues

**"Could not assume role with OIDC: No OpenIDConnect provider found"**
- OIDC provider not configured in AWS account
- Create provider: `https://token.actions.githubusercontent.com` with audience `sts.amazonaws.com`

**"Not authorized to perform sts:AssumeRoleWithWebIdentity"**
- IAM role trust policy incorrect
- Verify `Federated` ARN matches account
- Check `token.actions.githubusercontent.com:sub` condition matches repo pattern

**"Unrecognized named-value: 'secrets'"**
- Attempting to use secrets in `with:` section
- Move secret references to `secrets:` section

**"Conflict: an artifact with this name already exists"**
- Workflow re-run with existing artifacts
- Fixed by `overwrite: true` in artifact upload (already configured)

## Acceptance Criteria Status

✅ **Reusable workflow framework exists**: Three core workflows in `.github/workflows/`

✅ **Central repo strategy**: Repository `signapse/reusable-workflows` established

✅ **Naming conventions**: Documented and consistently applied

✅ **Versioning/pinning guidance**: Multiple strategies documented with trade-offs

✅ **Required inputs**: All workflows have well-defined inputs with descriptions

✅ **Secrets passing**: Pattern documented and implemented

✅ **Gradual opt-in**: Migration strategy allows incremental adoption

✅ **Core shared actions**:
- Checkout: `actions/checkout@v4`
- Caching: Docker layer caching via BuildKit (implicit)
- Artifact upload: `deploy_info.json` pattern
- Security: OIDC authentication, least-privilege permissions

✅ **Examples**: Multiple real-world examples in `examples/` directory

## Future Enhancements

Potential additions to the reusable workflow framework:

- [ ] Test reporting workflow (JUnit XML, coverage reports)
- [ ] Security scanning integration (Trivy, Snyk, etc.)
- [ ] Slack/Teams notification workflow
- [ ] Database migration workflow
- [ ] Terraform/IaC deployment workflow
- [ ] Multi-region deployment workflow
- [ ] Blue/green deployment support
- [ ] Rollback workflow

## Contributing

When adding new reusable workflows:

1. Follow naming conventions (`verb-noun.yml`)
2. Document all inputs with descriptions and examples
3. Add example usage in `examples/`
4. Update this README
5. Test with multiple repositories before merging
6. Consider backward compatibility

## Support

For issues or questions about reusable workflows:
- Open an issue in this repository
- Tag `@devops-team` for urgent matters
- Check `examples/` directory for reference implementations
