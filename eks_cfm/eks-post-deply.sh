#!/bin/bash

set -euo pipefail

# Input: Replace these with your actual values or export them as env vars
CLUSTER_NAME=${CLUSTER_NAME:-afritech-eks-cluster}
REGION=${REGION:-us-east-2}
NAMESPACE="kube-system"
DATADOG_API_KEY=${DATADOG_API_KEY:-"REPLACE_ME"}

# Fetch AWS Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# IAM role name based on CloudFormation
ALB_ROLE_NAME="AmazonEKSLoadBalancerControllerRole-staging"
ALB_IAM_ROLE="arn:aws:iam::${ACCOUNT_ID}:role/${ALB_ROLE_NAME}"

# Update kubeconfig
echo "Updating kubeconfig for cluster ${CLUSTER_NAME}..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"

# Create service account for ALB controller (if not exists)
if ! kubectl get serviceaccount aws-load-balancer-controller -n "$NAMESPACE" > /dev/null 2>&1; then
  echo "Creating Kubernetes service account for ALB Controller..."
  kubectl create serviceaccount aws-load-balancer-controller -n "$NAMESPACE"
  kubectl annotate serviceaccount -n "$NAMESPACE" aws-load-balancer-controller \
    eks.amazonaws.com/role-arn="${ALB_IAM_ROLE}"
else
  echo "Service account already exists. Skipping creation."
fi

# Add and update Helm repos
helm repo add eks https://aws.github.io/eks-charts
helm repo add datadog https://helm.datadoghq.com
helm repo update

# Deploy AWS Load Balancer Controller
echo "Deploying AWS Load Balancer Controller..."
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n "$NAMESPACE" \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$REGION" \
  --set vpcId=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query "cluster.resourcesVpcConfig.vpcId" --output text) \
  --wait

# Deploy Datadog Agent
echo "Deploying Datadog Agent via Helm..."
helm upgrade --install datadog-agent datadog/datadog \
  --set datadog.apiKey="$DATADOG_API_KEY" \
  --set datadog.site="datadoghq.com" \
  --set agents.containerLogs.enabled=true \
  --set datadog.logs.enabled=true \
  --set datadog.apm.enabled=true \
  --set targetSystem=linux \
  --wait

echo "✅ Post-deployment complete."
