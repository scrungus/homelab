# jellyfin

Jellyfin running parallel to Plex over the **same** `/tank/Media` libraries
(mounted read-only — qBittorrent is the only writer). Reachable at
`jellyfin.lab`. Requests one time-sliced `nvidia.com/gpu` unit for NVENC/NVDEC
(see `helm/apps/nvidia-device-plugin.yaml`).

## Deploy-time (declarative, in git)

The chart handles the pod, GPU, media mounts, service, ingress, TLS and DNS.
PUID/PGID come from the reflected `user-id-secret`.

## First-run state (runtime, lives in the config PVC — NOT git)

Jellyfin keeps its users, libraries and encoding settings in its SQLite DB
under `/config`, which is a hostPath PVC (`/appdata/jellyfin`). That state was
provisioned **once** over the API by `scripts/first-run-setup.py`:

- admin user (credentials stored in Secret `jellyfin/jellyfin-admin`)
- 8 libraries mapping the `/media/*` folders to the matching Plex sections
- NVENC hardware transcoding enabled
- an API key named `media-hooks` (consumed by the media-hooks router to trigger
  scans; stored in Secret `media-hooks/media-hooks-secrets` as `JELLYFIN_TOKEN`)

If the config PVC is ever wiped, re-run the setup against a fresh (wizard-not-
completed) Jellyfin. It is idempotent about the wizard and safe to re-run:

```sh
# from anywhere with cluster network access (e.g. the media-hooks pod, which
# has python3); JF_PW becomes the admin password.
JF_PW=$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)
kubectl -n jellyfin create secret generic jellyfin-admin \
  --from-literal=username=admin --from-literal=password="$JF_PW" \
  --dry-run=client -o yaml | kubectl apply -f -

MHP=$(kubectl -n media-hooks get pod -l app=media-hooks -o jsonpath='{.items[0].metadata.name}')
kubectl -n media-hooks exec -i "$MHP" -- env JF_PW="$JF_PW" python3 - \
  < helm/jellyfin/scripts/first-run-setup.py
# copy the printed APIKEY=... into media-hooks-secrets as JELLYFIN_TOKEN
```

Retrieve the admin password any time with:

```sh
kubectl -n jellyfin get secret jellyfin-admin -o jsonpath='{.data.password}' | base64 -d; echo
```
