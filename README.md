kubesync script
===
synchronize configmap & secret between k8s clusters/namespaces


sync examples
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
./kubesync.sh --from ~/.kube/config1 --to ~/.kube/config2  --include 'config-*' -l label=val -- configmaps

# --watch
./kubesync.sh --from-namespace default --to-namespace default-copy --watch -- configmaps

# --watch-only
./kubesync.sh --from-namespace default --to-namespace default-copy --watch-only -- configmaps

# secrets
./kubesync.sh --to-namespace default-copy secrets

# --patch to apply jq filter
./kubesync.sh --to-namespace default-copy secrets --patch '.metadata.annotations["patched"]=""'

# do 'kubectl create/replace' instead of 'kubectl apply'
./kubesync.sh --to-namespace default-copy secrets --replace

```

`--by-label` examples
---

```
# sync to default-copy
kubectl apply -f-<<\EOF
{
  "apiVersion": "v1",
  "kind": "Secret",
  "metadata": {
    "name": "example-secret",
    "labels": { 
      "kubesync/copy-to": "default-copy"
    }
  }
  "type": "Opaque"
}
{
  "apiVersion": "v1",
  "kind": "Secret",
  "metadata": {
    "name": "example-secret-1",
    "labels": { 
      "kubesync/copy-to": ""
    },
    "annotations": {
      "kubesync/copy-to": "default-copy, default-copy2"
    }
  }
  "type": "Opaque"
}
EOF

# sync example-secret from default to default-copy namespace, example-secret-1 to default-copy and default-copy2
./kubesync.sh --namespace default --by-label 'kubesync/copy-to' --owner-refs secrets 

# watch
./kubesync.sh --namespace default --by-label 'kubesync/copy-to' --owner-refs secrets --watch

# watch only
./kubesync.sh --namespace default --by-label 'kubesync/copy-to' --owner-refs secrets --watch-only

# watch all namespaces (as a cluster service)
./kubesync.sh --namespace default --by-label 'kubesync/copy-to' --owner-refs secrets --watch --all-namespaces

```