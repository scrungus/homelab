# media-hooks

A tiny, dependency-free **event router** for the self-hosted media pipeline.

```
download ──▶ qBittorrent ──(torrent finished, category=%L)──▶ media-hooks ──┬──▶ Plex   (scan mapped section)
                                                                            └──▶ Jellyfin (library refresh)
```

qBittorrent's completion hook (`helm/qbittorrent` → `on_complete.sh`) makes a
single `GET /trigger?category=<cat>` call. This service owns the routing table
(category → Plex section, plus a Jellyfin refresh) and fans the event out. The
downloader stays dumb; adding a third consumer (a push notification, Immich, an
Arr) is a one-line edit to `router.py` and never touches qBittorrent.

The app is pure Python stdlib, mounted from a ConfigMap into a stock
`python:3.12-slim` image — **nothing to build or push to registry.lab**.

## Tokens (created out-of-band, never in git)

The Deployment reads `PLEX_TOKEN` / `JELLYFIN_TOKEN` from the Secret
`media-hooks-secrets` (both marked `optional`, so the pod runs without them and
simply skips whichever server has no token). Create/update it directly — it is
intentionally **not** managed by ArgoCD so real tokens stay out of the repo and
self-heal never clobbers them:

```sh
# Plex: Settings ▸ (any item) ▸ Get Info ▸ View XML — copy the X-Plex-Token
#       from the URL, or read it from the running server's Preferences.xml.
# Jellyfin: Dashboard ▸ API Keys ▸ + (after the first-run setup wizard).
kubectl -n media-hooks create secret generic media-hooks-secrets \
  --from-literal=PLEX_TOKEN='REPLACE_ME' \
  --from-literal=JELLYFIN_TOKEN='REPLACE_ME' \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n media-hooks rollout restart deploy/media-hooks
```

## Category → Plex section map

Lives in `router.py` (`CATEGORY_TO_PLEX_SECTION`). Current mapping matches this
Plex server's sections:

| qBittorrent category | Plex section | Library path        |
|----------------------|--------------|---------------------|
| `tv`                 | 3            | `/tank/Media/TVSeries`     |
| `movies`             | 2            | `/tank/Media/Movies`       |
| `anime`              | 1            | `/tank/Media/Anime`        |
| `animefilms`         | 4            | `/tank/Media/AnimeFilms`   |
| `documentaries`      | 7            | `/tank/Media/Documentaries`|
| `shortfilms`         | 5            | `/tank/Media/ShortFilms`   |
| `music`              | 6            | `/tank/Media/Music`        |

## Manual backfill / testing

```sh
kubectl -n media-hooks exec deploy/media-hooks -- \
  python -c "import urllib.request as u; print(u.urlopen('http://localhost:8080/trigger?category=tv').read())"
```
