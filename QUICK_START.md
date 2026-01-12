# Quick Start Guide

## Files Created

### Reusable Workflows (Core)

1. **`.github/workflows/build-and-push-ecr.yml`**
   - Builds Docker images with custom build args
   - Pushes to Amazon ECR with configurable tags
   - Creates deployment metadata artifact

2. **`.github/workflows/deploy-aws-lambda.yml`**
   - Deploys Docker images from ECR to AWS Lambda
   - Includes health checks and status monitoring
   - Extensible for future ECS/EKS support

### Example Workflows (Reference)

3. **`examples/caller-release.yml`**
   - Example: Trigger on GitHub release publication
   - Builds and deploys to dev automatically

4. **`examples/caller-manual-deploy.yml`**
   - Example: Manual deployment via workflow_dispatch
   - Deploy any version to any environment on-demand

5. **`examples/caller-multi-environment.yml`**
   - Example: Build once, deploy to multiple environments
   - Includes approval gates for staging/production

### Original Workflows (For Reference)

6. **`examples/release.yml`**
   - Your original release workflow

7. **`examples/deploy-dev.yml`**
   - Your original deployment workflow

---

## Getting Started in 3 Steps

### Step 1: Set Up AWS IAM Roles

Create two IAM roles with OIDC federation:

1. **Build Role** - For pushing to ECR
   ```
   Permissions: ECR push/pull
   Trust: GitHub OIDC provider
   ```

2. **Deploy Role** - For updating Lambda
   ```
   Permissions: Lambda update, get function
   Trust: GitHub OIDC provider
   ```

See [README.md](README.md#prerequisites) for detailed IAM policy examples.

### Step 2: Copy a Caller Workflow

Choose one of the example workflows and adapt it:

**For release automation:**
```bash
cp examples/caller-release.yml .github/workflows/release.yml
# Edit with your ECR URI, region, IAM roles, Lambda function names
```

**For manual deployments:**
```bash
cp examples/caller-manual-deploy.yml .github/workflows/manual-deploy.yml
# Edit with your configuration
```

### Step 3: Update Configuration

Edit your new workflow file and replace:
- `ecr_repository_uri`: Your ECR repository URI
- `aws_region`: Your AWS region
- `iam_role_arn`: Your IAM role ARNs
- `lambda_function_name`: Your Lambda function name(s)

---

## Minimal Working Example

Here's the simplest possible workflow to get started:

```yaml
# .github/workflows/deploy.yml
name: Deploy

on:
  workflow_dispatch:
    inputs:
      version:
        required: true
        type: string

permissions:
  id-token: write
  contents: read

jobs:
  build:
    uses: ./.github/workflows/build-and-push-ecr.yml
    with:
      ecr_repository_uri: YOUR_ECR_URI
      aws_region: YOUR_REGION
      iam_role_arn: YOUR_BUILD_ROLE_ARN
      image_tag: ${{ inputs.version }}
    permissions:
      id-token: write
      contents: read

  deploy:
    needs: build
    uses: ./.github/workflows/deploy-aws-lambda.yml
    with:
      lambda_function_name: YOUR_LAMBDA_NAME
      ecr_repository_uri: YOUR_ECR_URI
      image_tag: ${{ inputs.version }}
      aws_region: YOUR_REGION
      iam_role_arn: YOUR_DEPLOY_ROLE_ARN
    permissions:
      id-token: write
      contents: read
```

Replace the `YOUR_*` placeholders with your actual values and you're ready to go!

---

## Common Use Cases

### Use Case 1: Deploy on Release
Use `examples/caller-release.yml` - Automatically builds and deploys when you publish a GitHub release.

### Use Case 2: Manual Deployment
Use `examples/caller-manual-deploy.yml` - Manually trigger deployment of any version to any environment.

### Use Case 3: Progressive Rollout
Use `examples/caller-multi-environment.yml` - Build once, then progressively deploy to dev → staging → production with approval gates.

---

## Testing Your Setup

1. **Test Build Workflow:**
   ```bash
   # Trigger manually from GitHub Actions UI
   # or push a tag:
   git tag v1.0.0-test
   git push origin v1.0.0-test
   ```

2. **Verify ECR:**
   ```bash
   aws ecr describe-images \
     --repository-name your-repo \
     --region your-region
   ```

3. **Check Lambda:**
   ```bash
   aws lambda get-function \
     --function-name your-function \
     --region your-region
   ```

---

## Troubleshooting Quick Fixes

| Problem | Quick Fix |
|---------|-----------|
| `AccessDenied` when assuming role | Verify trust relationship in IAM role allows your GitHub repo |
| `invalid build argument` | Check `docker_build_args` is one per line: `KEY=VALUE` |
| Docker build fails | Verify Dockerfile exists at `dockerfile_path` |
| Lambda not updating | Check IAM role has `lambda:UpdateFunctionCode` permission |
| Workflow can't be found | Ensure workflows are in `.github/workflows/` directory |

For detailed troubleshooting, see [README.md](README.md#troubleshooting).

---

## Next Steps

1. Review the [full README](README.md) for detailed documentation
2. Customize the workflows for your specific needs
3. Set up GitHub environments for approval gates
4. Add notifications (Slack, email, etc.)
5. Consider adding automated tests before deployment

---

## Support

- Full Documentation: [README.md](README.md)
- GitHub Actions Docs: https://docs.github.com/en/actions
- AWS Lambda Docs: https://docs.aws.amazon.com/lambda/
- AWS ECR Docs: https://docs.aws.amazon.com/ecr/
