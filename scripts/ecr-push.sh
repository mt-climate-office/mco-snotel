#!/usr/bin/env bash
# Build the image from a clean checkout of HEAD and push it to ECR as
# sha-<short commit>. Never pushes latest: production runs the digest pinned
# in terraform/image.auto.tfvars, so pushing deploys nothing.
# Prints the commit and the pushed digest to put in image_digest.
# Usage: ./scripts/ecr-push.sh
set -euo pipefail

REGION="us-west-2"
PROFILE="mco"
REPO_NAME="mco-snotel"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The tag names a commit, so refuse to build uncommitted changes.
if [ -n "$(git -C "${REPO_ROOT}" status --porcelain --untracked-files=no)" ]; then
  echo "Uncommitted changes in ${REPO_ROOT}; commit or stash them first." >&2
  exit 1
fi
COMMIT="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
IMAGE_TAG="sha-${COMMIT:0:7}"

ACCOUNT_ID="$(aws sts get-caller-identity --profile "${PROFILE}" --query Account --output text)"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}"

echo "=== Authenticating with ECR ==="
aws ecr get-login-password --region "${REGION}" --profile "${PROFILE}" \
  | docker login --username AWS --password-stdin "${ECR_URI}"

# Build from the committed tree only, so untracked files never reach the image.
CONTEXT="$(mktemp -d)"
trap 'rm -rf -- "${CONTEXT:?}"' EXIT
git -C "${REPO_ROOT}" archive "${COMMIT}" | tar -x -C "${CONTEXT}"

# A single image manifest (no attestations): its digest is what a task
# definition pins, and no untagged children are left for the lifecycle policy.
echo "=== Building and pushing ${ECR_URI}:${IMAGE_TAG} ==="
docker buildx build \
  --platform linux/amd64 \
  --provenance=false --sbom=false \
  --tag "${ECR_URI}:${IMAGE_TAG}" \
  --push \
  "${CONTEXT}"

DIGEST="$(aws ecr describe-images --repository-name "${REPO_NAME}" \
  --image-ids imageTag="${IMAGE_TAG}" --region "${REGION}" --profile "${PROFILE}" \
  --query 'imageDetails[0].imageDigest' --output text)"

echo "=== Done ==="
echo "commit: ${COMMIT}"
echo "tag:    ${ECR_URI}:${IMAGE_TAG}"
echo "digest: ${DIGEST}"
echo "To deploy, set image_digest = \"${DIGEST}\" in terraform/image.auto.tfvars."
