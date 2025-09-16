#!/bin/bash

PROFILE=${1:-live}

# Use environment variables with fallback defaults
PROJECT_ID=${PROJECT_ID:-"riley-genai-demo"}
REGION=${REGION:-"australia-southeast1"}
SERVICE_NAME=${SERVICE_NAME:-"nginx"}

case $PROFILE in
  dev)
    SOURCE_YAML="resources/dev.yaml"
    ;;
  prod)
    SOURCE_YAML="resources/prod.yaml"
    ;;
  *)
    SOURCE_YAML="resources/local.yaml"
    ;;
esac

# Try to get the current live service (will be empty if doesn't exist)
gcloud run services describe $SERVICE_NAME --format=export --region $REGION --project $PROJECT_ID > resources/tmp/current_input.yaml 2>/dev/null || echo "" > resources/tmp/current_input.yaml

# Substitute environment variables in the source YAML and merge with current service
envsubst < $SOURCE_YAML | yq '. *d load("resources/tmp/current_input.yaml")' > resources/tmp/current_output.yaml

# Cleanup temporary files
rm resources/tmp/current_input.yaml
