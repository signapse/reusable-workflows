# Helm Chart Template

This is a production-ready Helm chart template for deploying containerized applications to Kubernetes/EKS.

## Features

- ✅ Deployment with configurable replicas
- ✅ Service (ClusterIP, LoadBalancer, NodePort)
- ✅ Ingress support
- ✅ ServiceAccount with IAM role annotations (for EKS IRSA)
- ✅ Horizontal Pod Autoscaler (HPA)
- ✅ Configurable resource limits
- ✅ Health checks (liveness and readiness probes)
- ✅ Environment variables support
- ✅ Volume mounts support

## Quick Start

### 1. Copy this template to your repository

```bash
cp -r examples/helm-chart-template your-repo/helm/my-app
cd your-repo/helm/my-app
```

### 2. Customize for your application

Edit `Chart.yaml`:
```yaml
name: my-app  # Change to your app name
version: 1.0.0
appVersion: "1.0.0"
```

Edit `templates/_helpers.tpl` and replace all instances of `my-app` with your app name.

### 3. Create environment-specific values

Create `values-dev.yaml`:
```yaml
replicaCount: 1

image:
  repository: 827204657141.dkr.ecr.eu-west-2.amazonaws.com/my-app
  tag: "dev-latest"

env:
  - name: NODE_ENV
    value: "development"
  - name: API_URL
    value: "https://api.dev.example.com"

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

autoscaling:
  enabled: true
  minReplicas: 1
  maxReplicas: 5
```

### 4. Test locally

```bash
# Lint the chart
helm lint .

# Dry-run to see generated YAML
helm template my-app . -f values-dev.yaml

# Install to cluster
helm upgrade --install my-app . -f values-dev.yaml --namespace dev --create-namespace
```

## Directory Structure

```
my-app/
├── Chart.yaml              # Chart metadata
├── values.yaml             # Default values
├── templates/
│   ├── _helpers.tpl        # Template helpers
│   ├── deployment.yaml     # Deployment resource
│   ├── service.yaml        # Service resource
│   ├── ingress.yaml        # Ingress resource (optional)
│   ├── serviceaccount.yaml # ServiceAccount resource
│   └── hpa.yaml           # HorizontalPodAutoscaler (optional)
└── README.md              # This file
```

## Configuration

### Image

```yaml
image:
  repository: your-ecr-repo/your-app
  tag: "v1.0.0"
  pullPolicy: IfNotPresent
```

### Service Account (EKS IRSA)

For AWS EKS with IAM Roles for Service Accounts:

```yaml
serviceAccount:
  create: true
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789:role/my-app-role
```

### Ingress

```yaml
ingress:
  enabled: true
  className: nginx  # or kong, alb, etc.
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  hosts:
    - host: my-app.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: my-app-tls
      hosts:
        - my-app.example.com
```

### Autoscaling

```yaml
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 80
  targetMemoryUtilizationPercentage: 80
```

### Health Checks

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 30
  periodSeconds: 10

readinessProbe:
  httpGet:
    path: /ready
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 5
```

### Environment Variables

```yaml
env:
  - name: DATABASE_URL
    value: "postgresql://db:5432/myapp"
  - name: API_KEY
    valueFrom:
      secretKeyRef:
        name: my-app-secrets
        key: api-key
```

## Usage with GitHub Actions

Use with the `deploy-eks-helm.yml` reusable workflow:

```yaml
jobs:
  deploy:
    uses: signapse/reusable-workflows/.github/workflows/deploy-eks-helm.yml@main
    with:
      aws_region: "eu-west-2"
      iam_role_arn: "arn:aws:iam::123456789:role/github-access"
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

## Common Customizations

### Add ConfigMap

Create `templates/configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "my-app.fullname" . }}
  labels:
    {{- include "my-app.labels" . | nindent 4 }}
data:
  config.json: |
    {
      "feature": "enabled"
    }
```

Mount in deployment:
```yaml
volumes:
  - name: config
    configMap:
      name: my-app

volumeMounts:
  - name: config
    mountPath: /etc/config
    readOnly: true
```

### Add Secret

Create `templates/secret.yaml`:
```yaml
{{- if .Values.secrets }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "my-app.fullname" . }}
  labels:
    {{- include "my-app.labels" . | nindent 4 }}
type: Opaque
data:
  {{- range $key, $value := .Values.secrets }}
  {{ $key }}: {{ $value | b64enc | quote }}
  {{- end }}
{{- end }}
```

### Multiple Containers

Add sidecar container in deployment:
```yaml
containers:
  - name: {{ .Chart.Name }}
    # ... main container config

  - name: sidecar
    image: my-sidecar:latest
    ports:
      - containerPort: 9090
```

## Best Practices

1. **Always set resource limits** to prevent resource exhaustion
2. **Use health checks** to enable automatic recovery
3. **Enable autoscaling** for production workloads
4. **Use IRSA** for AWS permissions instead of static credentials
5. **Version your charts** using semantic versioning
6. **Test with `helm lint`** before deploying
7. **Use `--dry-run`** to preview changes
8. **Keep secrets in Kubernetes Secrets** or AWS Secrets Manager

## Troubleshooting

### Chart validation

```bash
# Lint chart
helm lint .

# Template chart (see generated YAML)
helm template my-app . -f values-dev.yaml

# Dry-run installation
helm upgrade --install my-app . -f values-dev.yaml --dry-run --debug
```

### Debugging deployments

```bash
# Check release status
helm status my-app -n my-namespace

# Get release values
helm get values my-app -n my-namespace

# View history
helm history my-app -n my-namespace

# Rollback
helm rollback my-app -n my-namespace
```

## Related Documentation

- [Helm Deployment Guide](../../docs/HELM-DEPLOYMENT-GUIDE.md)
- [Example Workflows](../)
- [Helm Documentation](https://helm.sh/docs/)
