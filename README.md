# Reusable Workflows

Central repository for GitHub Actions reusable workflows across Signapse projects.

## Overview

This repository provides a shared foundation of reusable workflows that individual project repositories can call into. The workflows follow consistent naming conventions, versioning strategies, and input/output patterns to ensure maintainability and avoid breaking changes.

## Repository Structure

```
.github/workflows/
├── build-and-push-ecr.yml          # Build Docker images and push to ECR
├── deploy-docker-image.yml         # Deploy Docker images to AWS (Lambda/ECS/EKS)
├── deploy-eks-helm.yml             # Deploy to EKS using Helm charts
├── build-and-deploy-lambda.yml     # Build and deploy Lambda functions
└── super-lint.yml                  # Code linting with Super-Linter

examples/
├── hub-platform-deployment.yml                    # Hub Platform release workflow
├── hub-platform-deploy-prod.yml                   # Hub Platform production deployment
├── video-translation-platform-deployment.yml      # Video Translation release workflow
├── video-translation-platform-deploy-prod.yml     # Video Translation production deployment
├── text2gloss-deployment.yml                      # Text2Gloss Lambda deployment
├── dev-portal-eks-helm-deployment.yml             # Dev Portal EKS Helm deployment example
├── simple-eks-helm-inline-values.yml              # EKS Helm with inline values example
├── remote-helm-chart-deployment.yml               # Remote Helm chart deployment example
├── lambda-nodejs-deployment.yml                   # Node.js Lambda deployment example
├── lambda-python-deployment.yml                   # Python Lambda deployment example
├── lambda-simple-deployment.yml                   # Simple Lambda (no build) example
├── lambda-with-layers.yml                         # Lambda with layers example
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

### 3. Deploy to EKS with Helm (`deploy-eks-helm.yml`)

Advanced EKS deployment workflow using Helm charts for Kubernetes application management.

**Purpose**: Deploy applications to Amazon EKS using Helm charts with full configuration flexibility

**Key Features**:
- 🎯 Helm 3 support with upgrade/install functionality
- 🔧 Flexible values configuration (files, inline, or --set parameters)
- 🐳 Automatic image URI override support
- 📊 Helm diff preview before deployment
- ⚡ Atomic rollbacks on failure
- 🔍 Automatic deployment verification
- 📦 Support for both local and remote Helm charts

**Inputs**:

*AWS Configuration:*
- `aws_region` (required): AWS region where EKS cluster is located
- `iam_role_arn` (required): IAM role ARN for OIDC authentication

*EKS Configuration:*
- `cluster_name` (required): EKS cluster name
- `namespace` (optional): Kubernetes namespace (default: `default`)
- `create_namespace` (optional): Create namespace if missing (default: `true`)

*Helm Configuration:*
- `release_name` (required): Helm release name
- `chart_path` (required): Path to Helm chart (local path or chart reference)
- `chart_version` (optional): Helm chart version (for remote charts)
- `values_file` (optional): Path to Helm values file
- `values_inline` (optional): Inline Helm values as YAML
- `set_values` (optional): Helm --set values (one per line)

*Docker Image Override:*
- `image_uri` (optional): Full Docker image URI to override in values
- `image_tag` (optional): Image tag to override

*Deployment Options:*
- `atomic` (optional): Rollback on failure (default: `true`)
- `wait` (optional): Wait for Pods to be ready (default: `true`)
- `timeout` (optional): Timeout for operations (default: `10m`)
- `force` (optional): Force resource updates (default: `false`)
- `dry_run` (optional): Simulate deployment (default: `false`)

*Helm Repository (for remote charts):*
- `helm_repo_name` (optional): Helm repository name
- `helm_repo_url` (optional): Helm repository URL

*Additional:*
- `post_deploy_command` (optional): Custom kubectl/helm command after deployment

**Usage Example (Local Chart with Values File)**:
```yaml
jobs:
  deploy-dev:
    uses: signapse/reusable-workflows/.github/workflows/deploy-eks-helm.yml@main
    with:
      # AWS Configuration
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::887333319954:role/github-access"

      # EKS Configuration
      cluster_name: "dev-cluster"
      namespace: "dev-portal"
      create_namespace: true

      # Helm Configuration
      release_name: "dev-portal"
      chart_path: "./helm/dev-portal"
      values_file: "./helm/values-dev.yaml"

      # Image Override
      image_uri: "827204657141.dkr.ecr.eu-west-2.amazonaws.com/dev-portal:v1.0.0"

      # Deployment Options
      atomic: true
      wait: true
      timeout: "10m"
    permissions:
      id-token: write
      contents: read
```

**Usage Example (Inline Values)**:
```yaml
jobs:
  deploy:
    uses: signapse/reusable-workflows/.github/workflows/deploy-eks-helm.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::887333319954:role/github-access"
      cluster_name: "dev-cluster"
      namespace: "app"
      release_name: "my-app"
      chart_path: "./helm/chart"

      # Inline YAML values
      values_inline: |
        replicaCount: 2
        image:
          repository: my-repo
          tag: v1.0.0
        service:
          type: ClusterIP
          port: 80

      # Additional overrides with --set
      set_values: |
        autoscaling.enabled=true
        autoscaling.minReplicas=2
    permissions:
      id-token: write
      contents: read
```

**Usage Example (Remote Chart from Helm Repository)**:
```yaml
jobs:
  deploy-nginx:
    uses: signapse/reusable-workflows/.github/workflows/deploy-eks-helm.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::887333319954:role/github-access"
      cluster_name: "prod-cluster"
      namespace: "nginx"

      # Remote chart configuration
      release_name: "nginx-ingress"
      chart_path: "bitnami/nginx"
      chart_version: "15.0.0"

      # Helm repository
      helm_repo_name: "bitnami"
      helm_repo_url: "https://charts.bitnami.com/bitnami"

      # Configuration
      set_values: |
        service.type=LoadBalancer
        replicaCount=3
    permissions:
      id-token: write
      contents: read
```

### 4. Build and Deploy Lambda (`build-and-deploy-lambda.yml`)

Comprehensive Lambda deployment workflow that builds, packages, and deploys Lambda functions with S3 backup and versioning.

**Purpose**: Automate Lambda function deployments across different runtimes with consistent packaging and deployment strategies

**Key Features**:
- 📦 Automatic zip package creation
- ☁️ S3 backup for audit trail and packages >50MB
- 🔄 Version publishing and alias management
- 🎯 Multi-runtime support (Node.js, Python, Java, Go, etc.)
- ⚙️ Configurable build commands for any build process
- 🚀 Direct upload (<50MB) or S3 deployment (>50MB)
- 🔧 Environment variables and configuration updates
- 📊 Layer support for shared dependencies

**Required Inputs**:
- `aws_region` (required): AWS region
- `iam_role_arn` (required): IAM role ARN for OIDC authentication
- `function_name` (required): Lambda function name
- `runtime` (required): Lambda runtime (nodejs18.x, nodejs20.x, python3.11, python3.12, java17, etc.)

**Common Optional Inputs**:
- `build_command`: Command to build/install dependencies (e.g., `npm ci --production`, `pip install -r requirements.txt -t .`)
- `source_dir`: Directory containing function code (default: `.`)
- `exclude_patterns`: Files to exclude from zip (default: tests, .git, .env, etc.)
- `include_files`: Specific files to include (default: all files)
- `s3_bucket`: S3 bucket for deployment packages (required for >50MB)
- `s3_prefix`: S3 key prefix (default: `lambda-deployments/FUNCTION_NAME/`)
- `publish_version`: Publish a new version (default: `true`)
- `update_alias`: Alias to update (e.g., `live`, `production`)
- `environment_variables`: JSON object of env vars
- `memory_size`: Memory in MB
- `timeout`: Timeout in seconds
- `layers`: Layer ARNs (one per line)

**Outputs**:
- `version`: Published Lambda version number
- `zip_size`: Size of deployment package in bytes
- Artifact: `lambda-deploy-info.json` with deployment metadata

**Usage Example (Python):**
```yaml
jobs:
  deploy:
    uses: signapse/reusable-workflows/.github/workflows/build-and-deploy-lambda.yml@main
    with:
      # AWS Configuration
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::123456789:role/github-access"

      # Lambda Configuration
      function_name: "my-python-function"
      runtime: "python3.12"

      # Build Configuration
      build_command: "pip install -r requirements.txt -t ."

      # Exclude test files
      exclude_patterns: |
        tests/
        __pycache__/
        *.pyc
        .env*

      # S3 Backup
      s3_bucket: "my-lambda-deployments"
      s3_prefix: "my-function/dev"

      # Deployment Options
      publish_version: true
      update_alias: "live"
      environment_variables: '{"ENV":"dev","LOG_LEVEL":"DEBUG"}'
      memory_size: 512
      timeout: 30
    permissions:
      id-token: write
      contents: read
```

**Usage Example (Node.js with TypeScript):**
```yaml
jobs:
  deploy:
    uses: signapse/reusable-workflows/.github/workflows/build-and-deploy-lambda.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::123456789:role/github-access"
      function_name: "my-nodejs-function"
      runtime: "nodejs20.x"

      # Build TypeScript
      build_command: |
        npm ci
        npm run build

      # Include only built files and production dependencies
      build_command: "npm ci --production"
      include_files: "dist/ node_modules/ package.json"

      # Exclude source files
      exclude_patterns: |
        src/
        *.ts
        tsconfig.json

      s3_bucket: "my-lambda-deployments"
      publish_version: true
      update_alias: "production"
    permissions:
      id-token: write
      contents: read
```

**Usage Example (Simple - No Build):**
```yaml
jobs:
  deploy:
    uses: signapse/reusable-workflows/.github/workflows/build-and-deploy-lambda.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::123456789:role/github-access"
      function_name: "simple-function"
      runtime: "python3.12"
      # No build_command needed
      s3_bucket: "my-lambda-deployments"
      publish_version: true
    permissions:
      id-token: write
      contents: read
```

**Usage Example (With Layers):**
```yaml
jobs:
  deploy:
    uses: signapse/reusable-workflows/.github/workflows/build-and-deploy-lambda.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::123456789:role/github-access"
      function_name: "my-function"
      runtime: "python3.12"

      # Only package app code
      source_dir: "src"

      # Dependencies in layers
      layers: |
        arn:aws:lambda:eu-west-2:123456789:layer:dependencies:1
        arn:aws:lambda:eu-west-2:123456789:layer:shared-utils:2

      s3_bucket: "my-lambda-deployments"
      publish_version: true
    permissions:
      id-token: write
      contents: read
```

**See also:** [Lambda Deployment Guide](./docs/LAMBDA-DEPLOYMENT-GUIDE.md) for detailed documentation, runtime-specific examples, and best practices.

### 5. Super Linter (`super-lint.yml`)

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

### Pattern 3: Build and Deploy to EKS with Helm

Complete workflow for building Docker images and deploying to EKS using Helm charts:

```yaml
name: Build and Deploy to EKS

on:
  push:
    branches: [main]
  release:
    types: [published]

permissions:
  id-token: write
  contents: read

jobs:
  # Build Docker image
  build:
    uses: signapse/reusable-workflows/.github/workflows/build-and-push-ecr.yml@main
    with:
      ecr_repository_uri: "827204657141.dkr.ecr.eu-west-2.amazonaws.com/my-app"
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::827204657141:role/github-actions-connect"
      image_tag: ${{ github.event_name == 'release' && github.event.release.tag_name || github.sha }}
      push_latest: false
    permissions:
      id-token: write
      contents: read

  # Deploy to Development (automatic on push)
  deploy-dev:
    if: github.event_name == 'push'
    needs: build
    uses: signapse/reusable-workflows/.github/workflows/deploy-eks-helm.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::887333319954:role/github-access"
      cluster_name: "dev-cluster"
      namespace: "my-app"
      release_name: "my-app"
      chart_path: "./helm/my-app"
      values_file: "./helm/values-dev.yaml"
      image_uri: "827204657141.dkr.ecr.eu-west-2.amazonaws.com/my-app:${{ github.sha }}"
      atomic: true
      wait: true
    permissions:
      id-token: write
      contents: read

  # Deploy to Production (only on release)
  deploy-prod:
    if: github.event_name == 'release'
    needs: build
    environment: production  # Requires manual approval
    uses: signapse/reusable-workflows/.github/workflows/deploy-eks-helm.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::430916267664:role/github-access"
      cluster_name: "prod-cluster"
      namespace: "my-app"
      release_name: "my-app"
      chart_path: "./helm/my-app"
      values_file: "./helm/values-prod.yaml"
      image_uri: "827204657141.dkr.ecr.eu-west-2.amazonaws.com/my-app:${{ github.event.release.tag_name }}"
      atomic: true
      wait: true
      timeout: "15m"
      set_values: |
        replicaCount=3
        autoscaling.minReplicas=3
    permissions:
      id-token: write
      contents: read
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

**ECS/EKS Deployments:**
- **Hub Platform**: Multi-environment ECS deployment with automatic dev deployment
- **Video Translation Platform**: Multi-environment ECS deployment
- **Dev Portal EKS Helm**: Complete build and Helm deployment to EKS with multiple environments
- **Simple EKS Helm**: Inline values example for EKS Helm deployments
- **Remote Helm Chart**: Deploying charts from remote repositories (Bitnami, Jetstack, etc.)

**Lambda Deployments:**
- **Text2Gloss**: Lambda deployment with dev/prod stages
- **Node.js Lambda**: TypeScript build and deployment
- **Python Lambda**: Python dependencies and deployment
- **Simple Lambda**: No-build deployment for simple scripts
- **Lambda with Layers**: Using shared layers for dependencies

**Generic Examples:**
- Reference implementations for common patterns

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

- [x] ~~Helm-based EKS deployment workflow~~ ✅ **Completed** (`deploy-eks-helm.yml`)
- [x] ~~Lambda build and deployment workflow~~ ✅ **Completed** (`build-and-deploy-lambda.yml`)
- [ ] Test reporting workflow (JUnit XML, coverage reports)
- [ ] Security scanning integration (Trivy, Snyk, etc.)
- [ ] Slack/Teams notification workflow
- [ ] Database migration workflow
- [ ] Terraform/IaC deployment workflow
- [ ] Multi-region deployment workflow
- [ ] Blue/green deployment support for EKS
- [ ] Canary deployment support for EKS and Lambda
- [ ] Automated rollback workflow
- [ ] Lambda layer build and publish workflow

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
