#!/usr/bin/env bash
set -e

section() {
  local msg="$1"
  local line="============================================================"
  local len=${#msg}
  local padding=$(( (60 - len) / 2 ))
  printf "\n%s\n" "$line"
  printf "%*s%s%*s\n" $padding "" "$msg" $padding ""
  printf "%s\n\n" "$line"
}

section "Starting bootstrap process..."

# 1. Start minikube
section "1. Starting Minikube"
minikube start --memory=4096 --cpus=2 --driver=docker

# 2. Install ArgoCD
section "2. Installing ArgoCD"
kubectl create namespace argocd || true
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

section "Waiting for ArgoCD server..."
kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd

# 3. Forward ArgoCD UI
section "3. Port-forwarding ArgoCD UI"
kubectl port-forward svc/argocd-server -n argocd 8080:80 > /tmp/argocd-portforward.log 2>&1 &

# 4. Apply root GitOps manifests
section "4. Applying root GitOps manifests"
kubectl apply -k manifests/

# 5. Wait for ArgoCD pods
section "5. Waiting for ArgoCD pods to become Ready..."
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=800s

# 6. Sync apps via ArgoCD CLI
section "6. Syncing apps in ArgoCD"
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

argocd login localhost:8080 \
  --username admin \
  --password $ARGOCD_PASS \
  --insecure

for app in monitoring spam2000; do
  section "Syncing app: $app"
  argocd app sync $app --timeout 100 || true
  argocd app wait $app --health --timeout 100 || true

  if [ "$app" == "monitoring" ]; then
    section "Waiting for VictoriaMetrics CRDs"
    for crd in vmagents vmsingles vmrules vmservicescrapes vmalerts vmalertmanagers; do
      kubectl wait --for=condition=Established crd/${crd}.operator.victoriametrics.com --timeout=120s || true
    done

    section "Re-syncing monitoring after CRDs are ready"
    argocd app sync monitoring --timeout 100 || true
    argocd app wait monitoring --health --timeout 100 || true
  fi
done

# 7. Forward Grafana
section "7. Port-forwarding Grafana"
kubectl wait --for=condition=available deployment/monitoring-grafana -n monitoring --timeout=45s
kubectl port-forward svc/monitoring-grafana -n monitoring 3000:80 > /tmp/grafana-portforward.log 2>&1 &

# 8. Forward Spam2000
section "8. Port-forwarding Spam2000 app"
kubectl wait --for=condition=available deployment/spam2000 -n default --timeout=45s
kubectl port-forward svc/spam2000 -n default 8081:3000 > /tmp/spam2000-portforward.log 2>&1 &

section "Bootstrap complete!"
echo "ArgoCD UI   → http://localhost:8080"
echo "Grafana UI  → http://localhost:3000"
echo "Spam2000 UI → http://localhost:8081"
