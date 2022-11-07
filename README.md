## Overview

This Terraform configuration creates an Amazon EC2 instance that uses cloud-init to install and run node_exporter. The Service listens on port 9100, and the metrics endpoint is open to the world. Data exposed by the metrics endpoint is not considered confidential so having it revealed is not a significant threat.

When creating Service Monitors, Prometheus Operator expects the services to be inside a Kubernetes cluster. Since the node_exporter target runs on an EC2 instance, it does not run inside a Kubernetes cluster and is not considered a "native" service.

By creating a service without a selector, Kubernetes does not know where to route traffic. Selectors tell Kubernetes which pods to route traffic to, but since the target is an EC2 instance and not a pod, no such selector exists.

Therefore, an Endpoints object is necessary. An Endpoints object contains references to a set of network endpoints. Each network endpoint must be an IP address, not a DNS name. Since public IP addresses are subject to change when restarting EC2 instances, an elastic IP is associated with the instance defined in this configuration. The Endpoints object references the public IP address of the elastic IP, which tells Kubernetes where to route service traffic.

Notice the name of the port "http-metrics." This name is critical when referencing it in the Service Monitor definition. If there is a mismatch in port names between the Service and its Service Monitor, then Prometheus Operator does not discover it. Once found, Prometheus Operator updates its scrape_configs to include the new Service. This automatic update prevents users from updating the Prometheus configuration manually, which prevents deploying malformed configurations.

## Getting Started

This configuration requires access to a Kubernetes cluster, an AWS account, Terraform, and the Prometheus Operator Custom Resource Definitions installed in the cluster.

This configuration uses [Kind](https://kind.sigs.k8s.io/) to bootstrap and run a Kubernetes cluster quickly. The [config.yaml](config.yaml) file contains the Kind cluster configuration. To create a cluster using the configuration file, simply run the following command:

```
kind create cluster --config config.yaml
kind export kubeconfig --name urban-disco
```

After creating the cluster, install the kube-prometheus-stack Helm chart by running the following commands:

```
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kube-prometheus-stack-1667743513 prometheus-community/kube-prometheus-stack
```

**Note:** Please do not change the release's name when installing the Helm chart. The release's name is critical since it tells Prometheus Operator which labels to target when discovering Service Monitors.

After installing the Helm chart, we can apply the Terraform configuration to create the necessary AWS and Kubernetes resources:

```
terraform init
terraform apply
```

After Terraform finishes creating the resources, port-forward the Prometheus service by running the following command and visit http://localhost:9090 in your web browser:

```
kubectl port-forward svc/kube-prometheus-stack-1667-prometheus 9090:9090
```

![localhost_9090_targets_search=](https://user-images.githubusercontent.com/2184329/200340010-beb806b0-ac3e-4c24-aa19-59b6fe667d54.png)
