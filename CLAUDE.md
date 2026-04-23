# homelab

Single-node k3s cluster (`high-end-machine`) managed by ArgoCD via this repo.
Every running thing on the cluster is expected to originate from here — if it
isn't in `helm/` and registered in `helm/apps/`, it shouldn't exist.

## Layout

- `helm/<name>/` — one wrapper chart per service. Either templates its own
  resources (e.g. `plex`, `qbittorrent`, `registry`, `coredns-config`,
  `cert-manager`) or depends on an upstream chart via `Chart.yaml` and overrides
  it through `values.yaml` (e.g. `immich`, `jupyterhub`, `argo-cd`,
  `kube-prometheus-stack`, `traefik`, `cloudnative-pg`).
- `helm/apps/<name>.yaml` — the ArgoCD `Application` that points at
  `helm/<name>/`. Adding one of these is what brings a service into the cluster.
- `helm/apps/root.yaml` — the app-of-apps. Watches `helm/apps/` with
  `directory.recurse: true`, so any new `Application` in that folder is picked
  up automatically on push. **Do not** `kubectl apply` new `Application`
  manifests manually.
- `helm/base-config/` — cluster-wide shared manifests (e.g. the PUID/PGID
  secret reused by Plex/qBittorrent).
- `manifests/`, `containers/`, `packages/` — pre-cluster / host-side artefacts
  kept for history. Not applied by ArgoCD.

## Conventions

### Adding a new service

1. `helm/<name>/Chart.yaml` + `values.yaml` (+ `templates/` if self-rendered).
2. `helm/apps/<name>.yaml` — `Application` with
   `spec.source.path: helm/<name>`, `destination.namespace: <name>`, and
   `syncPolicy.automated: {prune, selfHeal}`. Default `syncOptions`:
   `CreateNamespace=true`. Add `ServerSideApply=true` if any rendered CRD
   exceeds the 256KB client-side-apply annotation limit (CNPG, prometheus-operator).
3. If it needs DNS: append `100.66.242.14 <name>.lab` to
   `helm/coredns-config/templates/configmap.yaml`.
4. If it needs TLS: add a `Certificate` under
   `helm/cert-manager/templates/certificates/<name>.yaml` with
   `issuerRef.name: homelab-issuer` (the internal CA `ClusterIssuer`) and
   `secretName: <name>-tls`.
5. If it needs an ingress: a plain `networking.k8s.io/v1 Ingress` with
   `ingressClassName: traefik`, `tls.secretName: <name>-tls`, and host
   `<name>.lab`. See `helm/plex/templates/ingress.yaml` for the canonical shape.
6. Commit + push. App-of-apps syncs it within a minute or two. Do not run
   `kubectl apply` or `helm install` yourself.

### Sync order

ArgoCD sync waves are used sparingly — only where something provides a CRD
another app consumes. Current waves:
- `cert-manager`, `cloudnative-pg`, `kube-prometheus-stack-crds` are wave `-1`.
- Everything else is wave `0`.

If you add an operator whose CRDs are consumed elsewhere in the same sync,
annotate its `Application` with `argocd.argoproj.io/sync-wave: "-1"`.

### Storage

- `/tank` on the host is a **CIFS/SMB mount to 192.168.0.5** (not a local
  disk). Reads and writes across `/tank` go over the network both ways, even
  when source and destination are both under `/tank`.
- `/tank/Media/{Movies,TV,Photos,...}` — the ZFS datasets used as hostPath PVs
  for Plex, qBittorrent downloads, Immich, etc.
- Pattern for library volumes: hostPath `PersistentVolume` +
  `storageClassName: local-path` + bound `PersistentVolumeClaim` with a
  `claimRef`. See `helm/plex/templates/{pv,pvc}.yaml`.
- Ephemeral / small state (Postgres data dirs, Valkey queues, etc.): use the
  default `local-path` StorageClass and let it provision under `/var/lib/...`
  on the NVMe.

### Ingress / TLS / DNS

- Traefik is the only ingress controller. LB IP `100.66.242.14` (Tailscale).
- `*.lab` hostnames resolve via the `coredns-custom` ConfigMap
  (`helm/coredns-config/templates/configmap.yaml`) — additions to that file
  are the *only* DNS changes needed; no external record updates.
- TLS is self-signed via an internal `homelab-issuer` `ClusterIssuer` rooted
  at `root-ca` (`helm/cert-manager/templates/issuers/`). Browsers and most
  clients will warn; `curl` needs `-k`; `kubectl` is unaffected.
- Plex is the only service on a public Tailscale Funnel host. Don't add more
  funnel hosts without discussion — there's only one per tailnet.

### Traefik timeouts

`entryPoints.websecure.transport.respondingTimeouts.{read,write,idle}Timeout`
are set to `600s` in `helm/traefik/values.yaml` to accommodate large uploads
(Immich video import). The v2.11 defaults (60s readTimeout post
CVE-2024-28869) will 502 on multi-minute POSTs.

## Gotchas

- **bjw-s common library env scoping** (used by the immich chart): env vars
  placed at the top-level `controllers.main` leak into every pod the chart
  renders (server, ml, valkey). Scope DB creds under the relevant sub-block
  (e.g. `server.controllers.main.containers.main.env`) or sidecars will
  `CreateContainerConfigError` on a missing secret.
- **CNPG operator bootstrap race**: if the operator pod starts before its
  CRDs are installed it won't retry and will stay in `CrashLoopBackOff`.
  `kubectl -n cnpg-system delete pod -l app.kubernetes.io/name=cloudnative-pg`
  to recover.
- **CRDs over 256KB**: Helm's default client-side apply fails on the CNPG
  and prometheus-operator CRDs with `metadata.annotations: Too long`. The
  ArgoCD `Application` needs `ServerSideApply=true` in `syncOptions`.
- **Helm dependency artefacts** (`charts/`, `Chart.lock`) are gitignored and
  should stay that way — ArgoCD resolves them fresh on each sync.

## Out-of-band operations

- **Immich uploads / API**: there is a global `immich` skill with the server
  URL, API key, and the `immich-go` workflow (including the `--no-ui
  --log-file` flag that avoids the tview TUI panic in non-interactive
  shells). Use it rather than rediscovering those each time.
- **Restarting a stuck operator** or forcing a sync is fine via
  `kubectl`/`argocd` CLI, but **changing resources** is not — edit the chart
  and push.
