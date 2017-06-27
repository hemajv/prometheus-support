#!/bin/bash
#
# apply-global-prometheus.sh applies the global-prometheus configuration to the
# currently configured cluster. This script may be safely run multiple times to
# load the most recent configurations.
#
# If a config file (config/*) changes, the pod does not automatically restart
# when the configmap for that config file is updated. You must manually delete
# the pod, and kubernetes will recreate it with the new config.
#
# Example:
#
#   ./apply-global-prometheus.sh mlab-sandbox prometheus-federation

set -x
set -e
set -u

USAGE="$0 <projectid> <cluster>"
PROJECT=${1:?Please provide project id: $USAGE}
CLUSTER=${2:?Please provide cluster name: $USAGE}

export GRAFANA_DOMAIN=status-${PROJECT}.measurementlab.net
export ALERTMANAGER_URL=http://status-${PROJECT}.measurementlab.net:9093
# It does not really matter what the admin password is.
export GRAFANA_PASSWORD=$( echo $RANDOM | md5sum | awk '{print $1}' )

# Roles.
kubectl apply -f "k8s/${PROJECT}/${CLUSTER}/roles"

# Deployent dependencies.
kubectl apply -f "k8s/${PROJECT}/${CLUSTER}/persistentvolumes"

# Services.
kubectl apply -f "k8s/${PROJECT}/${CLUSTER}/services"

# Config maps and Secrets

## Blackbox exporter.
kubectl create configmap blackbox-config \
    --from-file=config/federation/blackbox \
    --dry-run -o json | kubectl apply -f -

## Prometheus
kubectl create configmap prometheus-federation-config \
    --from-literal=gcloud-project=${PROJECT} \
    --from-file=config/federation/prometheus \
    --dry-run -o json | kubectl apply -f -

## Grafana
kubectl create configmap grafana-config \
    --from-file=config/federation/grafana \
    --dry-run -o json | kubectl apply -f -

if [[ -n "$GRAFANA_PASSWORD" ]] ; then
  kubectl create secret generic grafana-secrets \
      "--from-literal=admin-password=${GRAFANA_PASSWORD}" \
      --dry-run -o json | kubectl apply -f -
fi
if [[ -n "${GRAFANA_DOMAIN}" ]] ; then
  kubectl create configmap grafana-env \
      "--from-literal=domain=${GRAFANA_DOMAIN}" \
      --dry-run -o json | kubectl apply -f -
fi

## Alertmanager
# TODO: enable storing slack channels as secrets and generating the config.yml
# Check to se if the alertmanager-config already exists. Do nothing if so.
AM_CONFIG=$( kubectl get configmaps \
    alertmanager-config --output=jsonpath={.metadata.name} )
if [[ -z "${AM_CONFIG}" ]] ; then
  # Create a default configuration without actual values.
  cp config/federation/alertmanager/config.yml.template \
      config/federation/alertmanager/config.yml

  # Create a new configmap.
  kubectl create configmap alertmanager-config \
      --from-file=config/federation/alertmanager \
      --dry-run -o json | kubectl apply -f -
fi

if [[ -n "${ALERTMANAGER_URL}" ]] ; then
    kubectl create configmap alertmanager-env \
        "--from-literal=external-url=${ALERTMANAGER_URL}" \
        --dry-run -o json | kubectl apply -f -
fi

# Deployments
kubectl apply -f "k8s/${PROJECT}/${CLUSTER}/deployments"

# Reload configurations. If the deployment configuration has changed then this
# request may fail becuase the container has already shutdown.
# TODO: there is an indeterminate delay between the time that a configmap is
# updated and it becomes available to the container. So, this reload may fail
# since the configmap is not yet up to date.
curl -X POST http://status-${PROJECT}.measurementlab.net:9090/-/reload || :
