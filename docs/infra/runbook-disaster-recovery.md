# Runbook: disaster recovery (rebuild from zero)

Scenario: the server is gone. State that survives: this repo, HCP Terraform
state, the hcloud PG volume (if intact), off-site backups on the Storage Box,
the age private key + sealing-key backup (password manager / Storage Box).

1. **Terraform**: `cd terraform && terraform apply`. The primary IP is
   reusable (`auto_delete=false`) — DNS does not change. If the volume
   survived, terraform re-attaches it and Postgres data is simply there.
2. **kubeconfig**: `ssh root@<ip> cat /etc/rancher/k3s/k3s.yaml` (IP swap).
3. **Restore the sealing key BEFORE bootstrapping ArgoCD** (otherwise the
   committed SealedSecrets can't decrypt):
   ```bash
   age -d -i ~/keys/norviq-backup.agekey cluster-state-<date>.yaml.age > cluster-state.yaml
   # apply only the sealed-secrets key Secret from that file first:
   kubectl apply -f <(yq 'select(.metadata.labels."sealedsecrets.bitnami.com/sealed-secrets-key" == "active")' cluster-state.yaml)
   ```
4. **Bootstrap GitOps**: `kubectl apply -k cluster/argocd && kubectl apply -f argocd/root.yaml`.
   Everything (addons, apps, secrets, cronjobs) converges from git.
5. **Database**: if the volume was lost, restore the newest off-site dump into
   `stockplan_production` (see restore drill, target the real DB).
6. **TLS**: cert-manager re-issues via HTTP-01 automatically once DNS resolves.
7. **Verify** with the cutover checklist step 5.

Expected time: under 1 hour, dominated by apt/image pulls and pg_restore.
