# Fluent Bit (Phase 3)

One shared pipeline (`values-base.yaml`, chart `fluent/fluent-bit` 0.58.3, image 5.1.3) for every
Kubernetes cluster of every project. Each cluster only adds a small identity file:

```yaml
# integrations/<project>/clusters/<cluster>.yaml
identity:
  project: tribe
  cluster: <cluster name>      # as registered in ArgoCD; unique across all projects
  env: dev                     # dev | staging | prod
```

## What the pipeline does

```
/var/log/containers/*.log  (every pod on the node, new pods picked up automatically)
  → tail      remembers its position (no loss or repeats on restart), buffers on the node's disk
  → kubernetes  adds namespace, pod, container, labels (app); JSON log lines become fields
  → modify    sets project, cluster, env from the identity file
  → es        appends to data stream logs-<project> as user fluentbit-<project>, TLS verified;
              retries forever while Elasticsearch is unreachable (up to 5G held per node)
```

## Before installing in a cluster

1. Elasticsearch is set up (Phases 1 and 2) and `apply.sh` has created the user `fluentbit-<project>`.
2. Set `elasticsearch.host` in `values-base.yaml` (replace `<ES_PRIVATE_DNS>`).
3. The cluster can reach Elasticsearch on port 9200 over the private network.
4. The secret `fluent-bit-es` exists in namespace `logging` of that cluster, with keys `password` (the
   `fluentbit-<project>` password) and `ca.crt` (Elasticsearch's CA). Create it from the secret manager,
   for example with an ExternalSecret; never commit it.

## Install

By hand (pilot cluster):

```sh
helm repo add fluent https://fluent.github.io/helm-charts && helm repo update
helm install fluent-bit fluent/fluent-bit --version 0.58.3 -n logging \
  -f install/logging/fluent-bit/values-base.yaml \
  -f integrations/tribe/clusters/<cluster>.yaml
```

With ArgoCD (all clusters): `argocd/fluent-bit-appset.yaml` deploys to every cluster that has a file in
`integrations/*/clusters/`. Register the cluster in ArgoCD under the same name as `identity.cluster`, add the
file, and ArgoCD installs Fluent Bit there.

## Check

```sh
kubectl -n logging get ds fluent-bit                 # DESIRED = READY = number of nodes
kubectl -n logging logs ds/fluent-bit | grep -iE 'error|warn' | tail
```

In Kibana Dev Tools:

```
GET logs-tribe/_search?size=0
{ "aggs": { "cluster": { "terms": { "field": "cluster" },
            "aggs": { "app": { "terms": { "field": "kubernetes.labels.app", "size": 50 },
                      "aggs": { "pods": { "cardinality": { "field": "kubernetes.pod_name" } } } } } } } }
```

Every cluster appears, with every app and its pod count.

## Changing settings later

| Change | Where |
| --- | --- |
| Elasticsearch address | `elasticsearch.host` in `values-base.yaml` |
| Disk buffer size per node | `storage.total_limit_size` in `values-base.yaml` |
| Drop noisy logs of one pod | Pod annotation `fluentbit.io/exclude: "true"` |
| Upgrade Fluent Bit | `image.tag` here and the chart version in the README / ApplicationSet, dev clusters first |
