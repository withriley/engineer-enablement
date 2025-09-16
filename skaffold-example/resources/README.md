# Skaffold Deployment Configuration

This directory contains all the configuration files and scripts needed for building and deploying an application using Skaffold.

## Prerequisites

Before running Skaffold commands, ensure you have the required gcloud components installed:

```bash
gcloud components install --quiet \
    alpha \
    beta \
    log-streaming \
    cloud-run-proxy
```

## Files Overview

### Configuration Files

- **`dev.yaml`** - Development environment overrides
- **`prod.yaml`** - Production environment overrides
- **`tmp/current_output.yaml`** - Final merged deployment configuration (auto-generated)

### Scripts

- **`collect.sh`** - Pre-deployment script that merges live service state with environment overrides

## Deployment Commands

### Development Workflow

```bash
# Local development with auto-cleanup (builds locally)
# Note: --profile=local not required due to activation: command: dev
skaffold dev

# Deploy to dev environment (Cloud Build)
skaffold run

# Deploy to production environment (Cloud Build)
skaffold run --profile=prod
```

## Environment Configuration

Configuration is hardcoded in `skaffold.yaml` with specific values for this project:

- **PROJECT_ID**: `riley-genai-demo`
- **REGION**: `australia-southeast1`
- **SERVICE_NAME**: Environment-specific names (`nginx-dev`, `nginx`, `nginx-testing`)

These values are set in the hook commands and used for:

- Google Cloud API calls
- Container image URLs (`australia-southeast1-docker.pkg.dev/riley-genai-demo/genai/`)
- Service deployment configuration

### Development Environment

- **Environment Variable**: `ENV=development`
- **Service Name**: `nginx-dev` (dev profile) or `nginx-testing` (local profile)
- **Build**: Cloud Build (default) or Local (`skaffold dev`)

### Production Environment

- **Environment Variable**: `ENV=production`
- **Service Name**: `nginx`
- **Build**: Cloud Build

## How It Works

### Deployment Process

1. **Pre-deployment Hook**: `collect.sh` script runs before deployment
   - Receives environment variables from Skaffold
   - Fetches current live service configuration (if exists)
   - Substitutes environment variables in YAML templates using `envsubst`
   - Merges live state with environment-specific overrides using `yq`
   - Generates final deployment configuration

2. **Build Phase**:
   - Local profile: Builds container locally
   - Default/prod profiles: Uses Google Cloud Build

3. **Deploy Phase**: Deploys to Google Cloud Run using merged configuration

### Configuration Merging

The `collect.sh` script performs these steps:

```bash
# Set environment variables (hardcoded in hook commands)
PROJECT_ID="riley-genai-demo"
REGION="australia-southeast1"
SERVICE_NAME="nginx-dev"  # or nginx, nginx-testing depending on profile

# Get current live service state
gcloud run services describe $SERVICE_NAME --format=export --region $REGION --project $PROJECT_ID > resources/tmp/current_input.yaml

# Merge with current service (no environment variable substitution in current setup)
yq '. *d load("resources/tmp/current_input.yaml")' < $SOURCE_YAML > resources/tmp/current_output.yaml
```

This ensures:

- Existing service configuration is preserved
- Only your specified changes are applied
- Service state remains consistent across deployments

### Environment Variable Substitution

The current YAML templates use hardcoded values:

```yaml
spec:
  template:
    spec:
      containers:
        - image: australia-southeast1-docker.pkg.dev/riley-genai-demo/genai/nginx
```

The service names are set directly in each environment file (`nginx-dev`, `nginx`, `nginx-testing`).

## Configuration Examples

### Adding Environment Variables

To add environment variables to an environment, edit the respective YAML file:

```yaml
spec:
  template:
    spec:
      containers:
        - env:
            - name: DATABASE_URL
              value: "your-database-url"
            - name: API_KEY
              valueFrom:
                secretKeyRef:
                  name: api-secrets
                  key: api-key
```

### Adjusting Resource Limits

```yaml
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/maxScale: '5'
        autoscaling.knative.dev/minScale: '1'
    spec:
      containers:
        - resources:
            limits:
              cpu: 1000m
              memory: 512Mi
```

### Service Annotations

```yaml
metadata:
  annotations:
    run.googleapis.com/ingress: all  # or internal-and-cloud-load-balancing
    run.googleapis.com/cpu-throttling: 'false'
    run.googleapis.com/execution-environment: gen2
```

## Customising Configuration

### Changing Project or Region

To deploy to a different project or region, update the hardcoded values in the hook commands in `skaffold.yaml`:

```yaml
hooks:
  before:
    - host:
        command: ["sh", "-c", "PROJECT_ID=your-project-id REGION=your-region SERVICE_NAME=your-service-name ./resources/collect.sh dev"]
```

### Adding New Environments

1. Create a new YAML file (e.g., `staging.yaml`)
2. Add a new profile to `skaffold.yaml`
3. Update the `collect.sh` case statement to handle the new environment

## Troubleshooting

### Common Issues

1. **Permission Errors**: Ensure you have Cloud Build and Cloud Run permissions
2. **Missing Dependencies**:
   - Install `yq` with `brew install yq` (macOS) or your package manager
   - Install `envsubst` (usually part of `gettext` package)
3. **Service Not Found**: First deployment will show warnings about missing live service - this is normal

### Debugging

```bash
# Check generated deployment config
cat resources/tmp/current_output.yaml

```bash
# Test collect script manually
export PROJECT_ID=riley-genai-demo
export REGION=australia-southeast1
export SERVICE_NAME=nginx-dev
./resources/collect.sh dev

# Check YAML template (no environment variable substitution in current setup)
cat resources/dev.yaml
```
```

## Project Configuration

Configuration is hardcoded in `skaffold.yaml` for this specific project:

- **Project ID**: `riley-genai-demo`
- **Region**: `australia-southeast1`
- **Service Names**: `nginx-dev` (dev), `nginx` (prod), `nginx-testing` (local)
- **Registry**: `australia-southeast1-docker.pkg.dev/riley-genai-demo/genai/`
