#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# AWS Platform Automation and DevSecOps Lab
# Safe API deployment with health checks and Nginx rollback
# ============================================================

AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="126309364316"
ECR_REPOSITORY="devsecops-lab-api"

NGINX_CONTAINER="nginx-test"
NGINX_CONFIG="/etc/nginx/conf.d/default.conf"
HOST_NGINX_CONFIG="/opt/devsecops-lab/nginx/default.conf"

DOCKER_NETWORK="devsecops-network"

# Set IMAGE_TAG to a Git commit SHA or another existing ECR tag.
IMAGE_TAG="${IMAGE_TAG:-}"

if [[ -z "${IMAGE_TAG}" ]]; then
    echo "ERROR: IMAGE_TAG is required."
    echo "Example: IMAGE_TAG=your-commit-sha $0"
    exit 1
fi

IMAGE_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}:${IMAGE_TAG}"

NEW_CONTAINER="devsecops-api-${IMAGE_TAG}"
NEW_CONTAINER="${NEW_CONTAINER:0:120}"

HOST_BACKUP="/tmp/default.conf.backup.$$"
HOST_NEW_CONFIG="/tmp/default.conf.new.$$"

DEPLOYMENT_SUCCEEDED=0
SWITCH_STARTED=0
ROLLBACK_RUNNING=0
BACKUP_CREATED=0

# ------------------------------------------------------------
# Rollback handler
# ------------------------------------------------------------

rollback() {
    local exit_code=$?

    trap - ERR
    set +e

    if [[ "${ROLLBACK_RUNNING}" -eq 1 ]]; then
        exit "${exit_code}"
    fi

    ROLLBACK_RUNNING=1

    if [[ "${DEPLOYMENT_SUCCEEDED}" -eq 1 ]]; then
        exit "${exit_code}"
    fi

    echo
    echo "============================================================"
    echo "DEPLOYMENT FAILED"
    echo "Attempting safe recovery..."
    echo "============================================================"

    if [[ "${SWITCH_STARTED}" -eq 1 && "${BACKUP_CREATED}" -eq 1 ]]; then

        if cat "${HOST_BACKUP}" > "${HOST_NGINX_CONFIG}" &&
           docker exec "${NGINX_CONTAINER}" nginx -t &&
           docker exec "${NGINX_CONTAINER}" nginx -s reload; then

            echo "Previous Nginx configuration restored."

            if curl --silent --show-error --fail \
                --max-time 5 \
                http://127.0.0.1/api/health; then
                echo
                echo "Health check passed after rollback."
            else
                echo
                echo "WARNING: Health check failed after rollback."
            fi

        else
            echo "CRITICAL: Automatic Nginx rollback failed."
            echo "Inspect the Nginx container immediately."
        fi
    else
        echo "Nginx switch had not started; existing routing was not changed."
    fi

    echo "Existing API containers have not been intentionally removed."
    echo "Review the deployment logs before retrying."

    exit "${exit_code}"
}

trap rollback ERR

# ------------------------------------------------------------
# 1. Verify prerequisites
# ------------------------------------------------------------

echo "============================================================"
echo "Starting API deployment"
echo "Image: ${IMAGE_URI}"
echo "============================================================"

command -v docker >/dev/null
command -v curl >/dev/null
command -v aws >/dev/null

docker info >/dev/null

docker inspect "${NGINX_CONTAINER}" >/dev/null

docker network inspect "${DOCKER_NETWORK}" >/dev/null

# Verify the host-side Nginx configuration exists.
test -f "${HOST_NGINX_CONFIG}"
test -w "${HOST_NGINX_CONFIG}"


# Ensure the expected Nginx configuration exists.
docker exec "${NGINX_CONTAINER}" \
    test -f "${NGINX_CONFIG}"

# ------------------------------------------------------------
# 2. Save the currently active Nginx configuration
# ------------------------------------------------------------

echo
echo "Saving current Nginx configuration..."

docker cp \
    "${NGINX_CONTAINER}:${NGINX_CONFIG}" \
    "${HOST_BACKUP}"

test -s "${HOST_BACKUP}"

BACKUP_CREATED=1

# ------------------------------------------------------------
# 3. Authenticate with Amazon ECR
# ------------------------------------------------------------

echo
echo "Authenticating with Amazon ECR..."

aws ecr get-login-password \
    --region "${AWS_REGION}" |
docker login \
    --username AWS \
    --password-stdin \
    "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# ------------------------------------------------------------
# 4. Pull the requested image
# ------------------------------------------------------------

echo
echo "Pulling image..."

docker pull "${IMAGE_URI}"

# ------------------------------------------------------------
# 5. Avoid overwriting an existing container
# ------------------------------------------------------------

REUSE_CONTAINER=0

if docker inspect "${NEW_CONTAINER}" >/dev/null 2>&1; then
    EXISTING_IMAGE=$(docker inspect "${NEW_CONTAINER}" --format '{{.Config.Image}}')
    EXISTING_RUNNING=$(docker inspect "${NEW_CONTAINER}" --format '{{.State.Running}}')

    if [[ "${EXISTING_IMAGE}" != "${IMAGE_URI}" ||
          "${EXISTING_RUNNING}" != "true" ]]; then
        echo "ERROR: Existing container is not the expected running image."
        exit 1
    fi

    echo "Reusing existing running API container: ${NEW_CONTAINER}"
    REUSE_CONTAINER=1
fi

# ------------------------------------------------------------
# 6. Start the new API container
# ------------------------------------------------------------

echo
echo "Starting new API container..."

if [[ "${REUSE_CONTAINER}" -eq 0 ]]; then
docker run -d \
    --name "${NEW_CONTAINER}" \
    --network "${DOCKER_NETWORK}" \
    --restart unless-stopped \
    --label "project=aws-platform-devsecops-lab" \
    --label "deployment-image=${IMAGE_URI}" \
    "${IMAGE_URI}"
fi

# ------------------------------------------------------------
# 7. Wait for the new API to become healthy
# ------------------------------------------------------------

echo
echo "Waiting for the new API to become healthy..."

HEALTHY=0

for attempt in $(seq 1 30); do

    if docker exec "${NEW_CONTAINER}" \
        python -c \
        "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3)" \
        >/dev/null 2>&1; then

        HEALTHY=1
        break
    fi

    echo "Health check attempt ${attempt}/30..."

    sleep 2
done

if [[ "${HEALTHY}" -ne 1 ]]; then
    echo "ERROR: New API did not become healthy."
    docker logs --tail 100 "${NEW_CONTAINER}" || true
    false
fi

echo "New API health check passed."

# ------------------------------------------------------------
# 8. Prepare the new Nginx configuration outside conf.d
# ------------------------------------------------------------

echo
echo "Preparing the Nginx configuration..."

sed \
    "s|http://api:8000/|http://${NEW_CONTAINER}:8000/|g" \
    "${HOST_BACKUP}" > "${HOST_NEW_CONFIG}"

# Ensure both routes point to the new container.
grep -Fq \
    "http://${NEW_CONTAINER}:8000/health" \
    "${HOST_NEW_CONFIG}"

grep -Fq \
    "http://${NEW_CONTAINER}:8000/info" \
    "${HOST_NEW_CONFIG}"

# Confirm the old configuration contains the expected routes.
grep -Fq "/api/health" "${HOST_BACKUP}"
grep -Fq "/api/info" "${HOST_BACKUP}"

# Copy the candidate to /tmp inside the Nginx container.
# Do not place a second *.conf file in conf.d.
docker cp \
    "${HOST_NEW_CONFIG}" \
    "${NGINX_CONTAINER}:/tmp/default.conf.candidate"

# ------------------------------------------------------------
# 9. Validate the candidate before switching Nginx
# ------------------------------------------------------------

echo
echo "Validating the candidate Nginx configuration..."

# Create a separate directory for candidate validation.
docker exec "${NGINX_CONTAINER}" \
    mkdir -p /tmp/nginx-candidate/conf.d

# Place only the candidate server configuration in that directory.
docker exec "${NGINX_CONTAINER}" sh -c \
    "cp /tmp/default.conf.candidate /tmp/nginx-candidate/conf.d/default.conf"

# Build an isolated main configuration using the candidate include.
docker exec "${NGINX_CONTAINER}" sh -c \
    "sed 's|include /etc/nginx/conf.d/\*.conf;|include /tmp/nginx-candidate/conf.d/*.conf;|' /etc/nginx/nginx.conf > /tmp/nginx-candidate/nginx.conf"

# Confirm that the candidate include is present.
docker exec "${NGINX_CONTAINER}" \
    grep -Fq \
    'include /tmp/nginx-candidate/conf.d/*.conf;' \
    /tmp/nginx-candidate/nginx.conf

# Test the candidate without replacing the live configuration.
docker exec "${NGINX_CONTAINER}" \
    nginx -t -c /tmp/nginx-candidate/nginx.conf

echo "Candidate Nginx configuration validation passed."

# ------------------------------------------------------------
# 10. Switch Nginx to the new API
# ------------------------------------------------------------

echo
echo "Switching Nginx to the new API..."

# Enable rollback immediately before replacing the active file.
SWITCH_STARTED=1

cat "${HOST_NEW_CONFIG}" > "${HOST_NGINX_CONFIG}"

# Validate the installed configuration before reloading.
docker exec "${NGINX_CONTAINER}" nginx -t

docker exec "${NGINX_CONTAINER}" nginx -s reload

echo "Nginx reloaded successfully."

# ------------------------------------------------------------
# 10. Test the API through Nginx
# ------------------------------------------------------------

echo
echo "Testing /api/health..."

curl \
    --silent \
    --show-error \
    --fail \
    --retry 5 \
    --retry-delay 2 \
    --retry-connrefused \
    --max-time 10 \
    http://127.0.0.1/api/health

echo

echo
echo "Testing /api/info..."

curl \
    --silent \
    --show-error \
    --fail \
    --retry 5 \
    --retry-delay 2 \
    --retry-connrefused \
    --max-time 10 \
    http://127.0.0.1/api/info

echo

# ------------------------------------------------------------
# 11. Mark deployment successful
# ------------------------------------------------------------

DEPLOYMENT_SUCCEEDED=1

echo
echo "============================================================"
echo "DEPLOYMENT SUCCESSFUL"
echo "============================================================"
echo "Image: ${IMAGE_URI}"
echo "New API container: ${NEW_CONTAINER}"
echo "Nginx container: ${NGINX_CONTAINER}"
echo "Previous API containers were not removed."
echo "Nginx backup: ${HOST_BACKUP}"
echo "============================================================"

echo
echo "Review the running containers with:"
echo "sudo docker ps"
