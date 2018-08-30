kubesync script
===
synchronize configmap & secret between k8s clusters/namespaces


examples
---

```
# copy all configmaps from default to another namespaces
./kubesync.sh --to-namespace default-copy configmaps

# single object
./kubesync.sh --to-namespace default-copy configmap/config-1 configmap/config-2

# with --from-namespace and conditions
./kubesync.sh --from-namespace default --to-namespace  --include 'config-*' -l label=val -- configmaps

# with --prune, delete dest configmap not in src namespace
./kubesync.sh --from-namespace default --to-namespace  --include 'config-*' -l label=val --prune configmaps

# with --owner-refs, automatically delete dest configmap when deleting src, refer https://kubernetes.io/docs/concepts/workloads/controllers/garbage-collection/
./kubesync.sh --from-namespace default --to-namespace  --include 'config-*' -l label=val --owner-refs configmaps

# between clusters
./kubesync.sh --from-config ~/.kube/config1 --to-config ~/.kube/config2  --include 'config-*' -l label=val -- configmaps

# --watch
./kubesync.sh --from-namespace default --to-namespace default-copy --watch -- configmaps

# --watch-only
./kubesync.sh --from-namespace default --to-namespace default-copy --watch-only -- configmaps

# secrets
./kubesync.sh --to-namespace default-copy secrets

```