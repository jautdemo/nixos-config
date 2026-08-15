# Flux (GitOps)

The cluster reconciles itself from this repo: branch **`main`**, path
`flux/clusters/home`.

## Layout

| path | what |
|---|---|
| `clusters/home/flux-system/` | controllers, written by `flux bootstrap` - don't hand-edit |
| `clusters/home/apps.yaml` | Kustomization -> `./k8s` (all manifests + secrets), **prunes** |
| `clusters/home/releases.yaml` | Kustomization -> `./flux/releases`, does **not** prune |
| `releases/` | the HelmReleases, their chart sources, and values files |

Values files live here rather than next to their app because a `HelmRelease`
cannot read a repo file - only a ConfigMap - and kustomize refuses to
reference files outside its own tree.

## Things that will surprise you

**Hand-made changes get reverted.** `kubectl edit`, `kubectl rollout restart`,
`kubectl scale` - Flux undoes all of it within 10 minutes. Change git instead.
To experiment against a live object, suspend first:

```sh
flux suspend kustomization apps      # or: flux suspend helmrelease <name>
# ... poke at things ...
flux resume kustomization apps
```

**`apps` prunes, `releases` does not.** Deleting a manifest from `k8s/` deletes
it from the cluster - that is the point. But pruning a HelmRelease *uninstalls
the release*; for cilium or longhorn a careless `git rm` would end the
cluster. Removing a release stays deliberate.

## Secrets

`k8s/**/*secret*.yaml` are SOPS-encrypted (values only - keys stay readable so
diffs remain meaningful). kustomize-controller decrypts in memory at apply
time using `flux-system/sops-age`.

Edit one with `sops k8s/<app>/<file>.yaml` - it re-encrypts on save. Never
`kubectl edit` a secret; Flux reverts it.

The age **public** key is in `.sops.yaml` and belongs in git. The **private**
key is in `flux-system/sops-age`, the password manager, and `secrets/sops-age.age`.
Encrypting it under agenix is not circular - agenix's trust root is the
YubiKeys, not this key. It is not a second backup either: lose both YubiKeys
and that copy goes with them, leaving the password manager. What it buys is a cluster
rebuild that does not start with pasting a key by hand.

Not in git: the `flux-system` deploy key, and cert-manager's self-generated
CA/account secrets (Flux would fight the controller that rotates them).

## Everyday commands

```sh
flux get kustomizations              # is everything applied?
flux get helmreleases -A             # are the releases healthy?
flux reconcile kustomization apps --with-source   # don't wait for the interval
flux diff kustomization apps --path ./k8s         # what would change?
```

Run these from a k8s node (`ssh duluth`, `KUBECONFIG=/etc/kubernetes/cluster-admin.kubeconfig`);
the `flux` CLI is available via `nix shell nixpkgs#fluxcd`.

Failing reconciliations are reported by `cluster-healthcheck` (check 10),
which pages through healthchecks.io, and by the FluxNotReporting /
FluxReconcileErrors Prometheus rules in `k8s/monitoring/flux-monitoring.yaml`.
