# House Map gateway

Routes `http://house.mama.lab` over Tailscale to the static House Map app on
TrueNAS (`100.95.146.90:3002`). No application workload or data runs in k3s.

The DNS record is declared in `helm/coredns-config/templates/configmap.yaml`.
The app, pinned release and NAS dataset are managed in `scrungus/mamas-cloud`.
