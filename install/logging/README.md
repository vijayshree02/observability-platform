# Logging: Elasticsearch + Kibana (Phase 1)

Installed once, in the cluster that hosts the log store. Versions: ECK operator 3.5.0, Elasticsearch and
Kibana 9.5.5.

## Layout

```
install/logging/
├── eck-operator-values.yaml    ECK operator (Helm values)
├── namespace.yaml              namespace logging
├── storageclass.yaml           expandable gp3 disks for Elasticsearch
├── elasticsearch/
│   └── elasticsearch.yaml      3-node Elasticsearch, internal load balancer
└── kibana/
    ├── kibana.yaml             Kibana
    └── ingress.yaml            HTTPS ingress for Kibana
```

## Before applying

Replace the placeholders:

| Placeholder | File | Value |
| --- | --- | --- |
| `<ES_PRIVATE_DNS>` | `elasticsearch/elasticsearch.yaml` | Private DNS name for Elasticsearch (Route 53 private record to the load balancer) |
| `<KIBANA_HOST>` | `kibana/kibana.yaml`, `kibana/ingress.yaml` | Public Kibana host name |
| `<CLUSTER_ISSUER>` | `kibana/ingress.yaml` | cert-manager ClusterIssuer used for the other ingresses |

Also add the VPC CIDR of every peered cluster and EC2 host to `loadBalancerSourceRanges` in
`elasticsearch/elasticsearch.yaml`. The cluster needs the EBS CSI driver add-on for `storageclass.yaml`.

## Install

```sh
helm repo add elastic https://helm.elastic.co && helm repo update
helm install elastic-operator elastic/eck-operator --version 3.5.0 \
  -n elastic-system --create-namespace -f install/logging/eck-operator-values.yaml

kubectl apply -f install/logging/namespace.yaml -f install/logging/storageclass.yaml
kubectl apply -f install/logging/elasticsearch/
kubectl apply -f install/logging/kibana/
```

## Check

```sh
kubectl -n logging wait --for=condition=Ready pod -l elasticsearch.k8s.elastic.co/cluster-name=logs --timeout=10m
kubectl -n logging get elasticsearch                 # HEALTH green, PHASE Ready
kubectl -n logging get kibana                        # HEALTH green
kubectl -n logging get svc logs-es-http              # EXTERNAL-IP is an internal load balancer
PW=$(kubectl -n logging get secret logs-es-elastic-user -o go-template='{{.data.elastic | base64decode}}')
curl -sk -u "elastic:$PW" "https://<ES_PRIVATE_DNS>:9200/_cluster/health?pretty"   # "status" : "green"
```

Then open `https://<KIBANA_HOST>` and log in as `elastic` with the same password.

## Changing settings later

| Setting | Where | Effect |
| --- | --- | --- |
| Disk size | `storage` in `elasticsearch/elasticsearch.yaml` | Volumes grow in place on re-apply (cannot shrink) |
| Memory | `resources` in `elasticsearch/elasticsearch.yaml` | Rolling restart, one node at a time |
| Allowed networks | `loadBalancerSourceRanges` | Load balancer security rules updated |
| Version | `version` in `elasticsearch.yaml` and `kibana.yaml` (keep them equal) | Rolling upgrade; upgrade only, never downgrade |
