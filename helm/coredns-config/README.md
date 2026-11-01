# Homelab DNS over Tailscale

CoreDNS serves the custom `.lab` records in `templates/configmap.yaml`.
ArgoCD deploys this chart through the `coredns-config` application.

The service exposes UDP and TCP DNS at both endpoints:

* `100.66.242.14:53` — the standard port for Tailscale nameserver settings.
* `100.66.242.14:32053` — the original NodePort for existing manual clients.

The external IP is the Tailscale address already assigned to `scrungus-beast`.
Kube-proxy routes traffic on that address; no new host listener or LoadBalancer
is needed on the current k3s cluster.

The `staging.mama.lab`, `admin.mama.lab`, and `commerce.mama.lab` records point
to Mama's TrueNAS server at `100.95.146.90`, rather than the homelab ingress.
Their HTTP ports are 3000, 3001, and 9002 respectively. Their app configuration
is managed in `scrungus/mamas-cloud`.

## Automatic client DNS

In the Tailscale admin console's **DNS** page, add a custom nameserver with
address `100.66.242.14` and restrict it to the domain `lab` for split DNS.
Devices with **Use Tailscale DNS** enabled then resolve `.lab` through this
server automatically while connected. The local `/etc/resolver/lab` workaround
is not required on new devices.

For all DNS traffic, the alternative is an unrestricted global nameserver plus
**Override DNS servers**. Check the CoreDNS upstreams first: the resolver must
not forward requests back into the Tailscale DNS configuration that points at
itself. A homelab outage would also affect public DNS for clients using it.

Verify direct resolver access from another Tailscale device:

```sh
dig @100.66.242.14 argocd.lab
dig +tcp @100.66.242.14 argocd.lab
dig @100.66.242.14 example.com
```

Use `tailscale dns status` to verify that clients actually received the `.lab`
route. A successful direct `dig` query alone does not confirm automatic DNS.
