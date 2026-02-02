# Lambda Deployment Guide

Complete guide for deploying AWS Lambda functions using the `build-and-deploy-lambda.yml` reusable workflow.

## Table of Contents

- [Quick Start](#quick-start)
- [Runtime-Specific Examples](#runtime-specific-examples)
- [Configuration Reference](#configuration-reference)
- [Common Patterns](#common-patterns)
- [Build Strategies](#build-strategies)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

## Quick Start

### Basic Lambda Deployment

```yaml
name: Deploy Lambda

on:
  release:
    types: [published]

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    uses: signapse/reusable-workflows/.github/workflows/build-and-deploy-lambda.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::123456789:role/github-access"
      function_name: "my-function"
      runtime: "python3.12"
      build_command: "pip install -r requirements.txt -t ."
      s3_bucket: "my-lambda-deployments"
    permissions:
      id-token: write
      contents: read
```

## Runtime-Specific Examples

### Node.js Lambda

**Project Structure:**
```
my-nodejs-lambda/
├── src/
│   └── index.js
├── package.json
├── package-lock.json
└── .github/
    └── workflows/
        └── deploy.yml
```

**Workflow:**
```yaml
jobs:
  deploy:
    uses: signapse/reusable-workflows/.github/workflows/build-and-deploy-lambda.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::123456789:role/github-access"
      function_name: "my-nodejs-function"
      runtime: "nodejs20.x"

      # Build: Install production dependencies
      build_command: |
        npm ci --production
        npm run build

      # Include built files and dependencies
      include_files: "dist/ node_modules/ package.json"

      # Exclude source and tests
      exclude_patterns: |
        src/
        tests/
        *.test.js
        .env*

      s3_bucket: "my-lambda-deployments"
      publish_version: true
```

### Python Lambda

**Project Structure:**
```
my-python-lambda/
├── lambda_function.py
├── requirements.txt
├── utils/
│   └── helper.py
└── .github/
    └── workflows/
        └── deploy.yml
```

**Workflow:**
```yaml
jobs:
  deploy:
    uses: signapse/reusable-workflows/.github/workflows/build-and-deploy-lambda.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::123456789:role/github-access"
      function_name: "my-python-function"
      runtime: "python3.12"

      # Install dependencies into current directory
      build_command: "pip install -r requirements.txt -t ."

      # Exclude Python cache and tests
      exclude_patterns: |
        __pycache__/
        *.pyc
        tests/
        .env*
        venv/

      s3_bucket: "my-lambda-deployments"
      publish_version: true
```

### Java Lambda

**Project Structure:**
```
my-java-lambda/
├── src/
│   └── main/
│       └── java/
├── pom.xml
└── .github/
    └── workflows/
        └── deploy.yml
```

**Workflow:**
```yaml
jobs:
  deploy:
    uses: signapse/reusable-workflows/.github/workflows/build-and-deploy-lambda.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::123456789:role/github-access"
      function_name: "my-java-function"
      runtime: "java17"

      # Build with Maven
      build_command: "mvn clean package"

      # Include only the JAR file
      source_dir: "target"
      include_files: "my-function.jar"

      s3_bucket: "my-lambda-deployments"
      publish_version: true
      memory_size: 1024
      timeout: 60
```

## Configuration Reference

### Required Inputs

| Input | Description | Example |
|-------|-------------|---------|
| `aws_region` | AWS region | `eu-west-2` |
| `iam_role_arn` | IAM role for OIDC | `arn:aws:iam::123:role/github-access` |
| `function_name` | Lambda function name | `my-function` |
| `runtime` | Lambda runtime | `python3.12`, `nodejs20.x`, `java17` |

### Build Configuration

| Input | Description | Default |
|-------|-------------|---------|
| `build_command` | Command to build/install deps | `''` (none) |
| `source_dir` | Source directory | `.` |
| `pre_build_command` | Command before build | `''` |
| `post_build_command` | Command after build | `''` |

### Package Configuration

| Input | Description | Default |
|-------|-------------|---------|
| `include_files` | Specific files to include | `''` (all) |
| `exclude_patterns` | Patterns to exclude | Common patterns |

**Default Exclusions:**
```
.git*
.github/
tests/
__tests__/
*.test.js
*.spec.js
.env*
.DS_Store
README.md
```

### S3 Configuration

| Input | Description | Required |
|-------|-------------|----------|
| `s3_bucket` | S3 bucket for packages | Required for >50MB |
| `s3_prefix` | S3 key prefix | Optional |
| `deploy_from_s3` | Deploy from S3 | `false` |

**Note:** Packages >50MB automatically use S3 deployment.

### Deployment Options

| Input | Description | Default |
|-------|-------------|---------|
| `publish_version` | Publish new version | `true` |
| `update_alias` | Alias to update | `''` |
| `environment_variables` | Env vars as JSON | `''` |
| `memory_size` | Memory in MB | `0` (no change) |
| `timeout` | Timeout in seconds | `0` (no change) |
| `layers` | Layer ARNs (one per line) | `''` |
| `architecture` | x86_64 or arm64 | `x86_64` |

## Common Patterns

### Pattern 1: Multi-Environment Deployment

```yaml
on:
  release:
    types: [published]

jobs:
  deploy-dev:
    uses: signapse/reusable-workflows/.github/workflows/build-and-deploy-lambda.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::887333319954:role/github-access"
      function_name: "my-function-dev"
      runtime: "python3.12"
      build_command: "pip install -r requirements.txt -t ."
      s3_bucket: "lambda-deployments-dev"
      environment_variables: '{"ENV":"dev","LOG_LEVEL":"DEBUG"}'
      publish_version: true
      update_alias: "live"

  deploy-prod:
    needs: deploy-dev
    environment: production  # Requires approval
    uses: signapse/reusable-workflows/.github/workflows/build-and-deploy-lambda.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::430916267664:role/github-access"
      function_name: "my-function-prod"
      runtime: "python3.12"
      build_command: "pip install -r requirements.txt -t ."
      s3_bucket: "lambda-deployments-prod"
      environment_variables: '{"ENV":"production","LOG_LEVEL":"INFO"}'
      publish_version: true
      update_alias: "production"
      memory_size: 1024
      timeout: 60
```

### Pattern 2: Monorepo with Multiple Functions

```yaml
jobs:
  deploy-function-a:
    uses: signapse/reusable-workflows/.github/workflows/build-and-deploy-lambda.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::123456789:role/github-access"
      function_name: "function-a"
      runtime: "nodejs20.x"
      source_dir: "functions/function-a"
      build_command: "npm ci --production"
      s3_bucket: "lambda-deployments"
      s3_prefix: "function-a"

  deploy-function-b:
    uses: signapse/reusable-workflows/.github/workflows/build-and-deploy-lambda.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::123456789:role/github-access"
      function_name: "function-b"
      runtime: "python3.12"
      source_dir: "functions/function-b"
      build_command: "pip install -r requirements.txt -t ."
      s3_bucket: "lambda-deployments"
      s3_prefix: "function-b"
```

### Pattern 3: Lambda with Layers

```yaml
jobs:
  deploy:
    uses: signapse/reusable-workflows/.github/workflows/build-and-deploy-lambda.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::123456789:role/github-access"
      function_name: "my-function"
      runtime: "python3.12"

      # Only package application code (deps in layer)
      source_dir: "src"

      # Reference shared layers
      layers: |
        arn:aws:lambda:eu-west-2:123456789:layer:common-deps:1
        arn:aws:lambda:eu-west-2:123456789:layer:shared-utils:2

      s3_bucket: "lambda-deployments"
      publish_version: true
```

### Pattern 4: Conditional Deployment

```yaml
on:
  workflow_dispatch:
    inputs:
      environment:
        type: choice
        options: [dev, staging, prod]
      function_name:
        type: string

jobs:
  deploy:
    uses: signapse/reusable-workflows/.github/workflows/build-and-deploy-lambda.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "${{
        inputs.environment == 'prod' &&
        'arn:aws:iam::430916267664:role/github-access' ||
        'arn:aws:iam::887333319954:role/github-access'
      }}"
      function_name: "${{ inputs.function_name }}-${{ inputs.environment }}"
      runtime: "python3.12"
      build_command: "pip install -r requirements.txt -t ."
      s3_bucket: "lambda-deployments-${{ inputs.environment }}"
      environment_variables: '{"ENV":"${{ inputs.environment }}"}'
```

## Build Strategies

### Strategy 1: No Build (Simple Scripts)

Perfect for simple Python/Node.js scripts with no dependencies.

```yaml
with:
  runtime: "python3.12"
  # No build_command needed
  source_dir: "."
```

### Strategy 2: Install Dependencies

Most common for Python and Node.js functions.

**Python:**
```yaml
with:
  runtime: "python3.12"
  build_command: "pip install -r requirements.txt -t ."
```

**Node.js:**
```yaml
with:
  runtime: "nodejs20.x"
  build_command: "npm ci --production"
```

### Strategy 3: Compile TypeScript

For TypeScript Lambda functions.

```yaml
with:
  runtime: "nodejs20.x"
  build_command: |
    npm ci
    npm run build
  include_files: "dist/ node_modules/ package.json"
  exclude_patterns: |
    src/
    *.ts
    tsconfig.json
```

### Strategy 4: Multi-Step Build

Complex builds with multiple steps.

```yaml
with:
  runtime: "python3.12"

  pre_build_command: |
    echo "Generating configuration..."
    python generate_config.py

  build_command: |
    pip install -r requirements.txt -t .
    python -m compileall .

  post_build_command: |
    echo "Cleaning up..."
    find . -type d -name "__pycache__" -exec rm -r {} +
```

### Strategy 5: Using Layers for Dependencies

Reduce deployment package size by using layers.

```yaml
with:
  runtime: "python3.12"

  # Only package app code
  source_dir: "src"

  # Dependencies in layer
  layers: |
    arn:aws:lambda:eu-west-2:123456789:layer:python-deps:1
```

## Best Practices

### 1. Use S3 for Backup and Audit

Always specify an S3 bucket:

```yaml
with:
  s3_bucket: "my-lambda-deployments"
  s3_prefix: "my-function/${{ github.ref_name }}"
```

Benefits:
- Audit trail of all deployments
- Rollback capability
- Required for packages >50MB

### 2. Version and Alias Strategy

```yaml
with:
  publish_version: true      # Always create versions
  update_alias: "live"       # Point alias to new version
```

Enables:
- Easy rollback: `aws lambda update-alias --function-version N-1`
- Traffic shifting
- Blue/green deployments

### 3. Environment-Specific Configuration

Use different configs per environment:

```yaml
environment_variables: '{"ENV":"${{ inputs.env }}","LOG_LEVEL":"${{ inputs.env == 'prod' && 'INFO' || 'DEBUG' }}"}'
memory_size: ${{ inputs.env == 'prod' && 1024 || 512 }}
timeout: ${{ inputs.env == 'prod' && 60 || 30 }}
```

### 4. Minimize Package Size

**Exclude unnecessary files:**
```yaml
exclude_patterns: |
  tests/
  *.test.*
  .env*
  README.md
  docs/
```

**Use layers for large dependencies:**
- boto3, requests (Python)
- aws-sdk (Node.js)
- Shared utilities

### 5. Test Before Production

```yaml
jobs:
  deploy-dev:
    # ... deploy to dev ...

  test-dev:
    needs: deploy-dev
    runs-on: ubuntu-latest
    steps:
      - name: Test function
        run: |
          # Invoke and test the function
          aws lambda invoke --function-name my-function-dev /tmp/response.json
          # Validate response

  deploy-prod:
    needs: test-dev
    environment: production
    # ... deploy to prod ...
```

### 6. Resource Configuration

Set appropriate limits:

```yaml
# For simple functions
memory_size: 128
timeout: 3

# For data processing
memory_size: 1024
timeout: 60

# For complex tasks
memory_size: 3008
timeout: 300
```

### 7. Security Best Practices

**Never commit secrets:**
```yaml
# ❌ Bad
environment_variables: '{"API_KEY":"secret123"}'

# ✅ Good - use Secrets Manager or Parameter Store
environment_variables: '{"SECRET_ARN":"arn:aws:secretsmanager:..."}'
```

**Use least privilege IAM:**
- Function execution role: minimum permissions
- Deployment role: only Lambda update permissions

## Troubleshooting

### Issue: Package Size >50MB

**Problem:** Direct upload fails for packages >50MB.

**Solutions:**

1. **Automatic S3 upload** (workflow handles this):
```yaml
with:
  s3_bucket: "my-deployments"  # Required for >50MB
```

2. **Use Layers:**
```yaml
with:
  layers: |
    arn:aws:lambda:region:account:layer:deps:1
```

3. **Reduce size:**
   - Remove dev dependencies
   - Use `--production` flag
   - Exclude unnecessary files

### Issue: Module Not Found

**Problem:** ImportError or MODULE_NOT_FOUND after deployment.

**Solutions:**

**Python:**
```yaml
# Ensure dependencies are in root
build_command: "pip install -r requirements.txt -t ."
```

**Node.js:**
```yaml
# Ensure node_modules is included
include_files: "dist/ node_modules/ package.json"
```

### Issue: Timeout During Deployment

**Problem:** Function update times out.

**Solution:**
The workflow waits up to 5 minutes. For large packages:

```yaml
with:
  deploy_from_s3: true  # Faster for large packages
  s3_bucket: "my-deployments"
```

### Issue: Function Returns Old Code

**Problem:** Deployed but still running old version.

**Solutions:**

1. **Check alias:**
```bash
aws lambda get-alias --function-name my-function --name live
```

2. **Force update:**
```yaml
with:
  publish_version: true
  update_alias: "live"  # Ensure this is set
```

### Issue: Environment Variables Not Updated

**Problem:** Env vars not changing after deployment.

**Solution:**
Environment variables are only updated if specified:

```yaml
with:
  environment_variables: '{"KEY":"value"}'  # Required to update
```

### Issue: Permission Denied

**Problem:** Unable to update function.

**Solutions:**

1. **Check IAM role:**
```json
{
  "Effect": "Allow",
  "Action": [
    "lambda:UpdateFunctionCode",
    "lambda:UpdateFunctionConfiguration",
    "lambda:PublishVersion",
    "lambda:UpdateAlias",
    "lambda:GetFunction"
  ],
  "Resource": "arn:aws:lambda:region:account:function:*"
}
```

2. **Check function policy** (resource-based policy)

## Advanced Examples

### Blue/Green Deployment

```yaml
jobs:
  deploy-green:
    uses: signapse/reusable-workflows/.github/workflows/build-and-deploy-lambda.yml@main
    with:
      function_name: "my-function"
      runtime: "python3.12"
      build_command: "pip install -r requirements.txt -t ."
      publish_version: true
      update_alias: "green"  # Deploy to green

  test-green:
    needs: deploy-green
    runs-on: ubuntu-latest
    steps:
      - name: Test green version
        run: |
          # Test the green alias
          aws lambda invoke --function-name my-function:green /tmp/response.json

  switch-traffic:
    needs: test-green
    runs-on: ubuntu-latest
    steps:
      - name: Update production alias
        run: |
          # Switch prod to green version
          VERSION=$(aws lambda get-alias --function-name my-function --name green --query FunctionVersion --output text)
          aws lambda update-alias --function-name my-function --name production --function-version $VERSION
```

### Canary Deployment

```yaml
steps:
  - name: Canary deployment
    run: |
      # Deploy new version
      VERSION=${{ needs.deploy.outputs.version }}

      # Route 10% traffic to new version
      aws lambda update-alias \
        --function-name my-function \
        --name production \
        --routing-config AdditionalVersionWeights={\"$VERSION\"=0.1}

      # Monitor for 10 minutes
      sleep 600

      # If successful, route all traffic
      aws lambda update-alias \
        --function-name my-function \
        --name production \
        --function-version $VERSION
```

## Related Documentation

- [Main README](../README.md)
- [Example Workflows](../examples/)
- [AWS Lambda Documentation](https://docs.aws.amazon.com/lambda/)
