# EKS Helm Deployment Guide

Complete guide for deploying applications to Amazon EKS using the `deploy-eks-helm.yml` reusable workflow.

## Table of Contents

- [Quick Start](#quick-start)
- [Workflow Features](#workflow-features)
- [Configuration Options](#configuration-options)
- [Common Use Cases](#common-use-cases)
- [Best Practices](#best-practices)
- [Advanced Examples](#advanced-examples)
- [Troubleshooting](#troubleshooting)

## Quick Start

### Prerequisites

1. **AWS Infrastructure**:
   - EKS cluster running and accessible
   - IAM role configured for OIDC authentication
   - Helm chart prepared (local or remote)

2. **GitHub Secrets** (optional):
   - `AWS_REGION`: AWS region (or pass as input)
   - Any sensitive configuration values

3. **Helm Chart Structure**:
```
your-repo/
├── helm/
│   ├── my-app/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   │       ├── deployment.yaml
│   │       ├── service.yaml
│   │       └── ingress.yaml
│   ├── values-dev.yaml
│   ├── values-staging.yaml
│   └── values-prod.yaml
└── .github/
    └── workflows/
        └── deploy.yml
```

### Basic Deployment Workflow

```yaml
name: Deploy to EKS

on:
  push:
    branches: [main]

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    uses: signapse/reusable-workflows/.github/workflows/deploy-eks-helm.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::123456789:role/github-access"
      cluster_name: "my-cluster"
      namespace: "my-app"
      release_name: "my-app"
      chart_path: "./helm/my-app"
      values_file: "./helm/values-dev.yaml"
      image_uri: "123456789.dkr.ecr.eu-west-2.amazonaws.com/my-app:latest"
    permissions:
      id-token: write
      contents: read
```

## Workflow Features

### 🎯 Core Capabilities

- **Helm 3 Support**: Uses latest Helm 3 features
- **Atomic Deployments**: Automatic rollback on failure
- **Diff Preview**: Shows changes before applying (requires helm-diff plugin)
- **Flexible Configuration**: Values files, inline YAML, or --set parameters
- **Image Override**: Easily override container images
- **Health Checks**: Waits for pods to be ready
- **Namespace Management**: Auto-create namespaces

### 🔧 Configuration Methods

The workflow supports three ways to configure values (can be combined):

1. **Values File**: `values_file: "./helm/values.yaml"`
2. **Inline Values**: YAML configuration directly in workflow
3. **Set Values**: Individual key=value overrides

**Precedence** (highest to lowest):
1. `set_values` (--set parameters)
2. `values_inline` (inline YAML)
3. `values_file` (values file)
4. Chart's default `values.yaml`

## Configuration Options

### Required Inputs

| Input | Description | Example |
|-------|-------------|---------|
| `aws_region` | AWS region | `eu-west-2` |
| `iam_role_arn` | IAM role for OIDC | `arn:aws:iam::123:role/github-access` |
| `cluster_name` | EKS cluster name | `production-cluster` |
| `release_name` | Helm release name | `my-application` |
| `chart_path` | Chart location | `./helm/chart` or `bitnami/nginx` |

### Important Optional Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `namespace` | `default` | Kubernetes namespace |
| `create_namespace` | `true` | Create namespace if missing |
| `atomic` | `true` | Rollback on failure |
| `wait` | `true` | Wait for pods to be ready |
| `timeout` | `10m` | Deployment timeout |
| `dry_run` | `false` | Simulate without applying |

### Image Override Options

| Input | Description | Example |
|-------|-------------|---------|
| `image_uri` | Full image URI | `123.dkr.ecr.eu-west-2.amazonaws.com/app:v1.0.0` |
| `image_tag` | Tag only | `v1.0.0` |

When `image_uri` is provided, it automatically sets:
- `--set image.repository=<repository>`
- `--set image.tag=<tag>`

## Common Use Cases

### 1. Basic Deployment with Values File

```yaml
jobs:
  deploy:
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
    permissions:
      id-token: write
      contents: read
```

### 2. Multi-Environment Deployment

```yaml
on:
  workflow_dispatch:
    inputs:
      environment:
        type: choice
        options: [dev, staging, prod]

jobs:
  deploy:
    uses: signapse/reusable-workflows/.github/workflows/deploy-eks-helm.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::887333319954:role/github-access"
      cluster_name: "${{ inputs.environment }}-cluster"
      namespace: "my-app"
      release_name: "my-app"
      chart_path: "./helm/my-app"
      values_file: "./helm/values-${{ inputs.environment }}.yaml"
      image_tag: "${{ inputs.environment }}-latest"
    permissions:
      id-token: write
      contents: read
```

### 3. Complete Build and Deploy Pipeline

```yaml
name: CI/CD Pipeline

on:
  push:
    branches: [main]
    tags: ['v*']

permissions:
  id-token: write
  contents: read

jobs:
  build:
    uses: signapse/reusable-workflows/.github/workflows/build-and-push-ecr.yml@main
    with:
      ecr_repository_uri: "827204657141.dkr.ecr.eu-west-2.amazonaws.com/my-app"
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::827204657141:role/github-actions-connect"
      image_tag: ${{ github.ref_name }}
    permissions:
      id-token: write
      contents: read

  deploy-dev:
    if: github.ref == 'refs/heads/main'
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
      image_uri: "827204657141.dkr.ecr.eu-west-2.amazonaws.com/my-app:${{ github.ref_name }}"
    permissions:
      id-token: write
      contents: read

  deploy-prod:
    if: startsWith(github.ref, 'refs/tags/v')
    needs: build
    environment: production  # Requires approval
    uses: signapse/reusable-workflows/.github/workflows/deploy-eks-helm.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::430916267664:role/github-access"
      cluster_name: "prod-cluster"
      namespace: "my-app"
      release_name: "my-app"
      chart_path: "./helm/my-app"
      values_file: "./helm/values-prod.yaml"
      image_uri: "827204657141.dkr.ecr.eu-west-2.amazonaws.com/my-app:${{ github.ref_name }}"
      timeout: "15m"
      set_values: |
        replicaCount=3
        autoscaling.minReplicas=3
        autoscaling.maxReplicas=20
    permissions:
      id-token: write
      contents: read
```

### 4. Inline Values (No Values File)

```yaml
jobs:
  deploy:
    uses: signapse/reusable-workflows/.github/workflows/deploy-eks-helm.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::887333319954:role/github-access"
      cluster_name: "dev-cluster"
      namespace: "my-app"
      release_name: "my-app"
      chart_path: "./helm/my-app"

      values_inline: |
        replicaCount: 2
        image:
          repository: 827204657141.dkr.ecr.eu-west-2.amazonaws.com/my-app
          tag: latest
          pullPolicy: Always
        service:
          type: ClusterIP
          port: 80
        ingress:
          enabled: true
          hosts:
            - host: my-app.example.com
              paths:
                - path: /
                  pathType: Prefix
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
    permissions:
      id-token: write
      contents: read
```

### 5. Remote Helm Chart (from Repository)

```yaml
jobs:
  deploy-nginx:
    uses: signapse/reusable-workflows/.github/workflows/deploy-eks-helm.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::887333319954:role/github-access"
      cluster_name: "prod-cluster"
      namespace: "ingress-nginx"

      # Remote chart
      release_name: "nginx-ingress"
      chart_path: "ingress-nginx/ingress-nginx"
      chart_version: "4.8.0"

      # Helm repository
      helm_repo_name: "ingress-nginx"
      helm_repo_url: "https://kubernetes.github.io/ingress-nginx"

      # Configuration
      set_values: |
        controller.service.type=LoadBalancer
        controller.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-type=nlb
    permissions:
      id-token: write
      contents: read
```

### 6. Dry-Run (Test Before Deploy)

```yaml
jobs:
  dry-run:
    uses: signapse/reusable-workflows/.github/workflows/deploy-eks-helm.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::887333319954:role/github-access"
      cluster_name: "prod-cluster"
      namespace: "my-app"
      release_name: "my-app"
      chart_path: "./helm/my-app"
      values_file: "./helm/values-prod.yaml"
      dry_run: true  # Simulate deployment
    permissions:
      id-token: write
      contents: read
```

## Best Practices

### 1. Environment-Specific Values Files

Organize values files by environment:

```
helm/
├── my-app/
│   ├── Chart.yaml
│   ├── values.yaml              # Default/shared values
│   └── templates/
├── values-dev.yaml               # Development overrides
├── values-staging.yaml           # Staging overrides
└── values-prod.yaml              # Production overrides
```

### 2. Use Atomic Deployments

Always use `atomic: true` in production to ensure automatic rollback on failure:

```yaml
with:
  atomic: true
  wait: true
  timeout: "15m"  # Longer timeout for production
```

### 3. Image Tag Strategy

**Development**:
```yaml
image_uri: "ecr.../my-app:${{ github.sha }}"  # Use commit SHA
```

**Production**:
```yaml
image_uri: "ecr.../my-app:${{ github.ref_name }}"  # Use tag name (v1.0.0)
```

### 4. Namespace Isolation

Create separate namespaces per environment or application:

```yaml
with:
  namespace: "my-app-${{ inputs.environment }}"
  create_namespace: true
```

### 5. Resource Limits

Always set resource requests and limits:

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

### 6. Health Checks

Configure readiness and liveness probes:

```yaml
readinessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 5

livenessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 30
  periodSeconds: 10
```

### 7. Use Secrets for Sensitive Data

Never commit secrets to values files. Use Kubernetes Secrets or AWS Secrets Manager:

```yaml
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: db-credentials
        key: password
```

### 8. Version Your Helm Charts

Use semantic versioning in `Chart.yaml`:

```yaml
apiVersion: v2
name: my-app
version: 1.2.3
appVersion: "v1.2.3"
```

## Advanced Examples

### Blue-Green Deployment Pattern

```yaml
jobs:
  deploy-green:
    uses: signapse/reusable-workflows/.github/workflows/deploy-eks-helm.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::887333319954:role/github-access"
      cluster_name: "prod-cluster"
      namespace: "my-app"
      release_name: "my-app-green"
      chart_path: "./helm/my-app"
      values_file: "./helm/values-prod.yaml"
      image_uri: "827204657141.dkr.ecr.eu-west-2.amazonaws.com/my-app:${{ github.ref_name }}"
      set_values: |
        service.selector.version=green
        podLabels.version=green
    permissions:
      id-token: write
      contents: read

  # After verification, switch traffic by updating blue deployment
```

### Post-Deployment Verification

```yaml
jobs:
  deploy:
    uses: signapse/reusable-workflows/.github/workflows/deploy-eks-helm.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::887333319954:role/github-access"
      cluster_name: "prod-cluster"
      namespace: "my-app"
      release_name: "my-app"
      chart_path: "./helm/my-app"
      values_file: "./helm/values-prod.yaml"
      post_deploy_command: |
        kubectl get pods -n my-app -l app=my-app
        kubectl wait --for=condition=ready pod -l app=my-app -n my-app --timeout=300s
    permissions:
      id-token: write
      contents: read
```

### Matrix Deployment (Multiple Environments)

```yaml
jobs:
  deploy:
    strategy:
      matrix:
        environment: [dev, staging]
        include:
          - environment: dev
            cluster: dev-cluster
            replicas: 1
          - environment: staging
            cluster: staging-cluster
            replicas: 2

    uses: signapse/reusable-workflows/.github/workflows/deploy-eks-helm.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::887333319954:role/github-access"
      cluster_name: "${{ matrix.cluster }}"
      namespace: "my-app"
      release_name: "my-app"
      chart_path: "./helm/my-app"
      values_file: "./helm/values-${{ matrix.environment }}.yaml"
      set_values: |
        replicaCount=${{ matrix.replicas }}
    permissions:
      id-token: write
      contents: read
```

## Troubleshooting

### Common Issues

#### 1. "helm: release: not found"

**Problem**: First deployment of a release.

**Solution**: This is expected for new releases. The workflow uses `helm upgrade --install` which handles both new and existing releases.

#### 2. "context deadline exceeded"

**Problem**: Deployment timeout.

**Solutions**:
- Increase timeout: `timeout: "20m"`
- Check pod events: `kubectl describe pod -n <namespace>`
- Review resource requests/limits
- Check image pull issues

#### 3. "failed to download chart"

**Problem**: Cannot fetch remote chart.

**Solutions**:
- Verify `helm_repo_url` is correct
- Ensure `helm_repo_name` matches chart prefix
- Check `chart_version` exists

#### 4. Atomic rollback triggered

**Problem**: Deployment failed and rolled back.

**Solutions**:
- Check workflow logs for error details
- Review pod logs: `kubectl logs -n <namespace> <pod-name>`
- Use `dry_run: true` to test configuration
- Disable atomic temporarily: `atomic: false` (not recommended for production)

#### 5. "Error: UPGRADE FAILED: timed out waiting for the condition"

**Problem**: Pods not becoming ready within timeout.

**Solutions**:
```yaml
with:
  timeout: "20m"  # Increase timeout
  wait: true      # Ensure this is true
```

Check pod status:
```bash
kubectl get pods -n <namespace>
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
```

### Debugging Commands

Add to `post_deploy_command` for debugging:

```yaml
post_deploy_command: |
  echo "=== Helm Release Status ==="
  helm status my-app -n my-app

  echo "=== Deployment Status ==="
  kubectl get deployment -n my-app

  echo "=== Pod Status ==="
  kubectl get pods -n my-app

  echo "=== Events ==="
  kubectl get events -n my-app --sort-by='.lastTimestamp'

  echo "=== Pod Logs ==="
  kubectl logs -l app=my-app -n my-app --tail=100
```

### Getting Help

If you encounter issues:

1. Check workflow logs in GitHub Actions
2. Review the examples in `examples/` directory
3. Use `dry_run: true` to test configuration
4. Check Kubernetes events and pod logs
5. Review Helm release history: `helm history <release> -n <namespace>`

## Related Documentation

- [Main README](../README.md)
- [Build and Push ECR Workflow](../README.md#1-build-and-push-to-ecr-build-and-push-ecryml)
- [Example Workflows](../examples/)
- [Helm Documentation](https://helm.sh/docs/)
- [EKS User Guide](https://docs.aws.amazon.com/eks/latest/userguide/)
