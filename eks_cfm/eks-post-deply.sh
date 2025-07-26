#!/bin/bash

set -euo pipefail
set -x  # Trace for debugging

CLUSTER_NAME="afritech-eks-cluster"
REGION="us-east-2"
NAMESPACE="kube-system"
DD_NAMESPACE="datadog"
POSTGRES_NAMESPACE="database"
POSTGRES_RELEASE_NAME="postgresql-ha"


echo "[INFO] Updating kubeconfig for cluster: $CLUSTER_NAME"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"

# -----------------------
# 🛡️ Create IRSA for AWS Load Balancer Controller
# -----------------------

echo "[INFO] Creating Kubernetes service account for AWS Load Balancer Controller"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/AmazonEKSLoadBalancerControllerRole-staging
EOF

# -----------------------
# Deploy AWS Load Balancer Controller
# -----------------------

echo "[INFO] Deploying AWS Load Balancer Controller via Helm"
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$REGION" \
  --set vpcId="vpc-1234567890abcdef0" \
  --set image.repository=602401143452.dkr.ecr.$REGION.amazonaws.com/amazon/aws-load-balancer-controller

# -----------------------
# Deploy Datadog via Helm
# -----------------------

echo "[INFO] Deploying Datadog Helm Chart"
helm repo add datadog https://helm.datadoghq.com
helm repo update

helm upgrade --install datadog-agent datadog/datadog \
  --namespace "$DD_NAMESPACE" --create-namespace \
  --set datadog.apiKey=DATADOG_API_KEY \
  --set datadog.site="datadoghq.com" \
  --set agents.containerLogs.enabled=true \
  --set daemonset.useHostPID=true

# -----------------------
# Deploy PostgreSQL-HA (Bitnami)
# -----------------------

echo "[INFO] Retrieving PostgreSQL passwords from AWS Secrets Manager..."
MASTER_PASSWORD=$(aws secretsmanager get-secret-value --secret-id postgresql-ha-master-password --query SecretString --output text)
REPLICATION_PASSWORD=$(aws secretsmanager get-secret-value --secret-id postgresql-ha-replication-password --query SecretString --output text)

echo "[INFO] Installing PostgreSQL-HA via Helm"
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm upgrade --install $POSTGRES_RELEASE_NAME bitnami/postgresql-ha \
  --namespace $POSTGRES_NAMESPACE --create-namespace \
  --set postgresql.password="$MASTER_PASSWORD" \
  --set postgresql.replicationPassword="$REPLICATION_PASSWORD" \
  --set fullnameOverride=postgresql-ha \
  --set global.storageClass=gp2 \
  --set nodeSelector."nodegroup"="nodegroup-1" \
  --set affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key="nodegroup" \
  --set affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator="In" \
  --set affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0]="nodegroup-1"

echo "[SUCCESS] EKS post-deployment setup completed."