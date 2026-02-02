# Lambda Deployment - Quick Start Guide

Quick guide to get your Lambda functions deployed using the central workflow.

## 🎯 Your Use Case

You have developers sending you zip files for Lambda deployment. This workflow automates:
1. ✅ Building/packaging the application on release
2. ✅ Creating the zip file automatically
3. ✅ Storing the zip in S3 for audit/backup
4. ✅ Deploying to Lambda
5. ✅ Publishing versions and updating aliases

## 🚀 Quick Setup

### Step 1: Identify Your Lambda Function Details

You'll need:
- Function name (e.g., `my-function-dev`)
- Runtime (e.g., `nodejs20.x`, `python3.12`)
- How it's currently built (ask your dev or check the zip contents)
- AWS region and IAM role ARN

### Step 2: Create Workflow in Lambda Repo

**File:** `.github/workflows/release.yml`

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
      # AWS Configuration
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::YOUR_ACCOUNT:role/github-access"

      # Lambda Configuration
      function_name: "YOUR_FUNCTION_NAME"
      runtime: "python3.12"  # or nodejs20.x, java17, etc.

      # Build command (ask your dev what they run to prepare the code)
      build_command: "pip install -r requirements.txt -t ."

      # S3 backup
      s3_bucket: "YOUR_LAMBDA_DEPLOYMENTS_BUCKET"

      # Deployment options
      publish_version: true
      update_alias: "live"

    permissions:
      id-token: write
      contents: read
```

### Step 3: Find the Right Build Command

Ask your developer: "What do you run before zipping the code?"

Common answers and solutions:

| Answer | build_command |
|--------|---------------|
| "I just zip the files" | Leave empty (no build needed) |
| "npm install" | `npm ci --production` |
| "pip install" | `pip install -r requirements.txt -t .` |
| "I run build.sh" | `bash build.sh` |
| "gradle build" | `gradle build` |
| "mvn package" | `mvn clean package` |

### Step 4: Test with a Release

1. Create a release in your Lambda repo
2. Watch the GitHub Actions workflow run
3. Verify Lambda function is updated

## 📋 Common Scenarios

### Scenario 1: Simple Python Script (No Dependencies)

```yaml
jobs:
  deploy:
    uses: signapse/reusable-workflows/.github/workflows/build-and-deploy-lambda.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::887333319954:role/github-access"
      function_name: "simple-function"
      runtime: "python3.12"
      # No build_command needed
      s3_bucket: "lambda-deployments"
```

### Scenario 2: Python with Requirements

```yaml
jobs:
  deploy:
    uses: signapse/reusable-workflows/.github/workflows/build-and-deploy-lambda.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::887333319954:role/github-access"
      function_name: "my-python-function"
      runtime: "python3.12"
      build_command: "pip install -r requirements.txt -t ."
      s3_bucket: "lambda-deployments"
```

### Scenario 3: Node.js Application

```yaml
jobs:
  deploy:
    uses: signapse/reusable-workflows/.github/workflows/build-and-deploy-lambda.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::887333319954:role/github-access"
      function_name: "my-nodejs-function"
      runtime: "nodejs20.x"
      build_command: "npm ci --production"
      s3_bucket: "lambda-deployments"
```

### Scenario 4: Multiple Environments

```yaml
jobs:
  deploy-dev:
    uses: signapse/reusable-workflows/.github/workflows/build-and-deploy-lambda.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::887333319954:role/github-access"
      function_name: "my-function-dev"
      runtime: "python3.12"
      build_command: "pip install -r requirements.txt -t ."
      s3_bucket: "lambda-deployments"
      environment_variables: '{"ENV":"dev"}'

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
      environment_variables: '{"ENV":"production"}'
```

## 🔍 Inspecting Developer's Zip File

If you have a zip file from your dev, inspect it to understand the structure:

```bash
# Extract and explore
unzip developer-sent.zip -d inspect-zip
cd inspect-zip

# Look for:
# - Source files (.py, .js, .java)
# - Dependencies (node_modules/, site-packages/, lib/)
# - Build artifacts (dist/, build/, target/)

# Python - check for dependencies
ls -la  # Look for packages installed alongside source

# Node.js - check for node_modules
ls -la node_modules/

# Check structure
tree -L 2
```

This tells you:
- What needs to be in `include_files`
- What `build_command` should install
- What `source_dir` should be

## 🆘 Troubleshooting

### "I don't know the build command"

**Option 1:** Ask the developer
**Option 2:** Check the zip file contents
**Option 3:** Start with no build command and add if needed

```yaml
# Start simple
with:
  function_name: "my-function"
  runtime: "python3.12"
  # No build_command
  s3_bucket: "deployments"
```

If it fails with "module not found", add:
```yaml
build_command: "pip install -r requirements.txt -t ."
```

### "Package is too large (>50MB)"

The workflow automatically handles this! Just ensure `s3_bucket` is set:

```yaml
with:
  s3_bucket: "lambda-deployments"  # Required for >50MB
```

### "How do I exclude files?"

```yaml
with:
  exclude_patterns: |
    tests/
    *.test.js
    .env*
    docs/
    README.md
```

### "Function exists but not deploying"

Check IAM permissions. The deployment role needs:
```json
{
  "Effect": "Allow",
  "Action": [
    "lambda:UpdateFunctionCode",
    "lambda:PublishVersion",
    "lambda:UpdateAlias"
  ],
  "Resource": "arn:aws:lambda:REGION:ACCOUNT:function:*"
}
```

## 📝 Template for Team

Share this with your team for new Lambda functions:

```yaml
name: Deploy to Lambda

on:
  release:
    types: [published]
  workflow_dispatch:  # Manual trigger for testing

permissions:
  id-token: write
  contents: read

jobs:
  deploy-dev:
    uses: signapse/reusable-workflows/.github/workflows/build-and-deploy-lambda.yml@main
    with:
      # TODO: Update these values
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::887333319954:role/github-access"
      function_name: "FUNCTION_NAME_HERE"
      runtime: "RUNTIME_HERE"  # python3.12, nodejs20.x, etc.

      # TODO: Add build command if needed
      # build_command: "pip install -r requirements.txt -t ."

      # S3 backup
      s3_bucket: "lambda-deployments"

      # Publish and alias
      publish_version: true
      update_alias: "live"

    permissions:
      id-token: write
      contents: read
```

## 📚 Next Steps

1. **Create S3 bucket** for Lambda deployments (if not exists):
   ```bash
   aws s3 mb s3://lambda-deployments-YOUR_ORG
   ```

2. **Set up one function** as a test

3. **Create a release** and watch it deploy

4. **Roll out to other functions**

5. **Read the full guide:** [Lambda Deployment Guide](./LAMBDA-DEPLOYMENT-GUIDE.md)

## 💡 Pro Tips

### Tip 1: Use Workflow Dispatch for Testing

```yaml
on:
  release:
    types: [published]
  workflow_dispatch:  # Add this for manual testing
```

Now you can test from GitHub Actions UI without creating a release!

### Tip 2: Check Package Contents

The workflow shows package contents in the logs:
```
Package contents:
  Archive:  /tmp/lambda-deployment.zip
  Length      Date    Time    Name
---------  ---------- -----   ----
     1234  12-01-2024 10:30   lambda_function.py
    56789  12-01-2024 10:30   utils/helper.py
```

### Tip 3: Use Aliases for Zero-Downtime

```yaml
with:
  publish_version: true      # Creates $LATEST, 1, 2, 3...
  update_alias: "live"       # Points 'live' to latest version
```

Your function ARN becomes: `arn:aws:lambda:region:account:function:name:live`

If deployment fails, alias still points to previous working version!

### Tip 4: Environment Variables

```yaml
with:
  environment_variables: '{"DB_HOST":"prod.db.com","LOG_LEVEL":"INFO"}'
```

Or use different values per environment:
```yaml
environment_variables: '${{
  inputs.env == "prod" &&
  "{\"DB_HOST\":\"prod.db.com\"}" ||
  "{\"DB_HOST\":\"dev.db.com\"}"
}}'
```

## 🤝 Getting Help

1. Check [Lambda Deployment Guide](./LAMBDA-DEPLOYMENT-GUIDE.md) for detailed docs
2. See [examples/](../examples/) for complete working examples
3. Open an issue in reusable-workflows repo
4. Check GitHub Actions logs for specific error messages
