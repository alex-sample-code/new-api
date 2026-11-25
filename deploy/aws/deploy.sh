#!/usr/bin/env bash
# Deploy / update the Linxi AI gateway on AWS. Idempotent: safe to re-run.
#
#   deploy/aws/deploy.sh image    # build + push the image for the current commit
#   deploy/aws/deploy.sh app      # regional stack (network, ALB, ECS, RDS, cache)
#   deploy/aws/deploy.sh edge     # CloudFront + WAF (us-east-1)
#   deploy/aws/deploy.sh all
#
# Settings live in deploy/aws/config.env; the origin secret in deploy/aws/.origin-secret
# (generated on first run, never committed).
set -euo pipefail
cd "$(dirname "$0")"
source ./config.env
ROOT=$(git rev-parse --show-toplevel)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REPO="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO"
TAG="${IMAGE_TAG:-$BASE_VERSION-linxi.$(git rev-parse --short HEAD)}"

if [[ ! -s .origin-secret ]]; then
  (umask 077; openssl rand -hex 32 > .origin-secret)
fi
ORIGIN_SECRET=$(cat .origin-secret)

image() {
  aws ecr describe-repositories --region "$REGION" --repository-names "$ECR_REPO" >/dev/null 2>&1 ||
    aws ecr create-repository --region "$REGION" --repository-name "$ECR_REPO" \
      --image-scanning-configuration scanOnPush=true --image-tag-mutability IMMUTABLE >/dev/null
  if aws ecr describe-images --region "$REGION" --repository-name "$ECR_REPO" --image-ids imageTag="$TAG" >/dev/null 2>&1; then
    echo "image $REPO:$TAG already pushed"; return
  fi
  (cd "$ROOT" && echo "$TAG" > VERSION && docker build -t "$REPO:$TAG" . ; rc=$?; git checkout -q VERSION; exit $rc)
  aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${REPO%%/*}"
  docker push "$REPO:$TAG"
}

origin_cert() {
  local arn
  arn=$(aws acm list-certificates --region "$REGION" --certificate-statuses ISSUED PENDING_VALIDATION \
    --query "CertificateSummaryList[?DomainName=='$ORIGIN_HOST'].CertificateArn | [0]" --output text)
  if [[ "$arn" == "None" ]]; then
    arn=$(aws acm request-certificate --region "$REGION" --domain-name "$ORIGIN_HOST" \
      --validation-method DNS --query CertificateArn --output text)
    sleep 8
  fi
  local rec
  rec=$(aws acm describe-certificate --region "$REGION" --certificate-arn "$arn" \
    --query 'Certificate.DomainValidationOptions[0].ResourceRecord.[Name,Value]' --output text)
  read -r name value <<<"$rec"
  aws route53 change-resource-record-sets --hosted-zone-id "$ORIGIN_ZONE_ID" --change-batch \
    "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$name\",\"Type\":\"CNAME\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"$value\"}]}}]}" >/dev/null
  aws acm wait certificate-validated --region "$REGION" --certificate-arn "$arn"
  echo "$arn"
}

app() {
  local cert pl
  cert=$(origin_cert | tail -1)
  pl=$(aws ec2 describe-managed-prefix-lists --region "$REGION" \
    --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
    --query 'PrefixLists[0].PrefixListId' --output text)
  aws cloudformation deploy --region "$REGION" --stack-name "$APP_STACK" \
    --template-file app-stack.yaml --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset \
    --parameter-overrides \
      VpcId="$VPC_ID" PublicSubnetIds="$PUBLIC_SUBNET_IDS" \
      PrivateSubnetACidr="$PRIVATE_A_CIDR" PrivateSubnetAAz="$PRIVATE_A_AZ" \
      PrivateSubnetBCidr="$PRIVATE_B_CIDR" PrivateSubnetBAz="$PRIVATE_B_AZ" \
      CloudFrontPrefixListId="$pl" OriginCertificateArn="$cert" \
      OriginVerifySecret="$ORIGIN_SECRET" ImageUri="$REPO:$TAG"
  local dns zone
  dns=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$APP_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='AlbDnsName'].OutputValue" --output text)
  zone=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$APP_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='AlbHostedZoneId'].OutputValue" --output text)
  aws route53 change-resource-record-sets --hosted-zone-id "$ORIGIN_ZONE_ID" --change-batch \
    "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$ORIGIN_HOST\",\"Type\":\"A\",\"AliasTarget\":{\"HostedZoneId\":\"$zone\",\"DNSName\":\"dualstack.$dns\",\"EvaluateTargetHealth\":false}}}]}" >/dev/null
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$APP_STACK" \
    --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text
}

edge() {
  aws cloudformation deploy --region us-east-1 --stack-name "$EDGE_STACK" \
    --template-file edge-stack.yaml --no-fail-on-empty-changeset \
    --parameter-overrides \
      OriginDomainName="$ORIGIN_HOST" OriginVerifySecret="$ORIGIN_SECRET" \
      ViewerCertificateArn="$VIEWER_CERT_ARN" Aliases="$ALIASES" \
      OriginReadTimeout="$ORIGIN_READ_TIMEOUT"
  local cf host type
  cf=$(aws cloudformation describe-stacks --region us-east-1 --stack-name "$EDGE_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='DistributionDomainName'].OutputValue" --output text)
  if [[ -n "${EDGE_ZONE_ID:-}" ]]; then
    for host in ${EDGE_ZONE_HOSTS//,/ }; do
      for type in A AAAA; do
        aws route53 change-resource-record-sets --hosted-zone-id "$EDGE_ZONE_ID" --change-batch \
          "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$host\",\"Type\":\"$type\",\"AliasTarget\":{\"HostedZoneId\":\"Z2FDTNDATAQYW2\",\"DNSName\":\"$cf\",\"EvaluateTargetHealth\":false}}}]}" >/dev/null
      done
    done
  fi
  aws cloudformation describe-stacks --region us-east-1 --stack-name "$EDGE_STACK" \
    --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text
}

case "${1:-}" in
  image) image ;;
  app) app ;;
  edge) edge ;;
  all) image; app; edge ;;
  *) sed -n 2,10p "$0"; exit 1 ;;
esac
