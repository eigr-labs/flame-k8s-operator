# Flame K8s Adapter

Advanced [Flame](https://github.com/phoenixframework/flame) [k8s](https://kubernetes.io) Adapter basead on [Operator Pattern](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/).

## Installation

### Install the operator

Use the release assets published for each GitHub release. This is the recommended installation flow for real clusters and does not require cloning the repository.

Latest release:

```bash
curl -fsSL https://github.com/eigr-labs/flame-k8s-operator/releases/latest/download/install-operator.sh \
  -o /tmp/install-operator.sh
bash /tmp/install-operator.sh --namespace flame
```

Pinned release tag:

```bash
curl -fsSL https://github.com/eigr-labs/flame-k8s-operator/releases/download/v0.1.0/install-operator.sh \
  -o /tmp/install-operator.sh
bash /tmp/install-operator.sh --tag v0.1.0 --namespace flame
```

The installer downloads the published manifest bundle, ensures the Erlang cookie secret exists, waits for the CRDs to become established, and applies the operator manifests.

If you need to apply raw YAML directly, use the files published in the GitHub Release assets instead of cloning the repo:

```bash
kubectl apply -f https://github.com/eigr-labs/flame-k8s-operator/releases/download/v0.1.0/namespace.yaml
kubectl apply -f https://github.com/eigr-labs/flame-k8s-operator/releases/download/v0.1.0/flamepool.crd.yaml
kubectl apply -f https://github.com/eigr-labs/flame-k8s-operator/releases/download/v0.1.0/flamerunner.crd.yaml
kubectl apply -f https://github.com/eigr-labs/flame-k8s-operator/releases/download/v0.1.0/deployment.yaml
```

### Install the Elixir backend library

If [available in Hex](https://hex.pm/docs/publish), the package can be installed by adding `flame_k8s` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:flame_k8s, "~> 0.1.0"}
  ]
end
```

> **_NOTE:_** The library and the Kubernetes operator are separate pieces. Install the operator in the cluster first, then add the backend library to your Elixir app.

### Local end-to-end validation (development only)

These commands are for contributors and local validation. They are not the installation flow for end users.

Run from repository root:

```bash
make local-e2e
```

The install flow now generates or reuses the operator Erlang cookie Secret at apply time.

- Operator namespace secret: `flame-erlang-cookie`
- Workload namespace copies are created by the operator when FLAME-enabled workloads or runners are admitted

Helper scripts:

```bash
bash scripts/install-operator.sh --manifest-dir .k8s/install/manifests --namespace flame
```

Release/tag based install for end users:

```bash
curl -fsSL https://raw.githubusercontent.com/eigr-labs/flame-k8s-operator/v0.1.0/scripts/install-operator.sh | bash -s -- --tag v0.1.0 --namespace flame
```

If `--tag` is omitted, the installer tries to resolve the latest GitHub release automatically.

Required local tools:

- `docker`
- `kubectl`
- `kind`

You can run only the preflight checks:

```bash
make preflight-local
```

Useful commands:

```bash
# Remove local validation cluster
make local-reset

# Only regenerate manifests for a specific image tag
make generate-k8s-manifests version=dev-local
```

By default, `local-e2e` uses:

- cluster name: `flame-local`
- operator namespace: `flame`
- operator image tag for local validation: `ghcr.io/eigr-labs/flame-k8s-controller:dev-local`

You can override Make variables when needed, for example:

```bash
make local-e2e cluster_name=my-cluster operator_namespace=flame version=dev-local
```

### Install Kubernetes Controller

To install the Kubernetes controller, use the GitHub Release asset installer shown above; do not rely on a repository checkout for normal deployment.

## Usage

Configure the flame backend in our configuration.

```elixir
# config.exs
if config_env() == :prod do
  config :flame, :backend, FLAME.K8sBackend
  config :flame, FLAME.K8sBackend, log: :debug
end
```

You need to enable Flame in Kubernetes as well. See the example below:

```yaml
# my-application.yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flame-parent-example
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: flame-parent-example
  template:
    metadata:
      annotations:
        flame.org/enabled: "true"
        flame.org/dist-auto-config: "true"
        flame.org/otp-app: "my_app_release_name"
    spec:
      containers:
        - image: eigr/flame-parent-example:1.1.1
          name: flame-parent-example
          resources:
            limits:
              cpu: 200m
              memory: 200Mi
            requests:
              cpu: 200m
              memory: 200Mi
```

The most important part is:

```yaml
template:
  metadata:
    annotations:
      flame.org/enabled: "true"
      flame.org/dist-auto-config: "true"
      flame.org/otp-app: "my_app_release_name"
```

See what each annotation means in the following table:

| Annotation                           | Default          | Detail        |
| -------------------------------------| -----------------| ------------- | 
| flame.org/enabled                    | "false"          | Enable or disable Flame. |
| flame.org/dist-auto-config           | "true"           | Auto configure RELEASE_DISTRIBUTION and RELEASE_NODE. When set to "false", automatic distribution env injection is disabled for both parent workload and generated runner pods.             |
| flame.org/otp-app                    |                  | Application release name. Required if dist-auto-config is set to "true".  |
| flame.org/pool-config-ref            | "default-pool"   | Flame Pool configuration reference name. See more in the Configuration section.           |
| flame.org/runner-termination-timeout | 60000            | Timeout in milliseconds that the Runner will have to finish before the controller sends the POD delete command.

Runner pod node naming is resolved differently from the parent workload mutation:

- Parent workload pod: webhook can inject `RELEASE_DISTRIBUTION=name` and `RELEASE_NODE=<otp-app>@$(POD_IP)`.
- FlameRunner pod: controller can build `RELEASE_NODE=$(FLAME_NODE_BASE)@$(POD_IP)` and use `RELEASE_DISTRIBUTION=name`.
- If `flame.org/dist-auto-config` is explicitly set to `"false"`, both parent and runner auto-injection are disabled and you can provide distribution env vars manually at your own risk.
- `FLAME_NODE_BASE` is provided by `FLAME.K8sBackend` when creating the `FlameRunner` resource.

Now you can start scaling your applications with [Flame](https://github.com/phoenixframework/flame)... with a little help from [eigr](https://github.com/eigr) \0/

## Configuration

The operator manages `FlamePool` resources, which define the reusable runner profiles used by workloads annotated with `flame.org/pool-config-ref`. In practice, a pool is the configuration contract that tells the controller how to schedule and build runner pods for a workload.

Each pool controls the scheduling class, architecture, priority, and pod template that will be used when a Flame-enabled application needs to spawn Kubernetes runners.

### 1. Flame Runner Pool

A `FlamePool` is not a raw pod definition; it is a higher-level profile that the controller translates into runner pod specifications. It allows you to standardize the runtime characteristics of your workers, such as CPU, memory, node class, lifecycle, and architecture, while keeping the application configuration simple.

To configure a new Runner Pool, define the following YAML and apply it to the Kubernetes cluster.

```yaml
# my-runner.yaml
---
apiVersion: flame.org/v1
kind: FlamePool
metadata:
  name: my-runner-pool
  namespace: default
spec:
  scheduling:
    provider: generic
    class: cpu
    lifecycle: on-demand
    architecture: amd64
    priority: normal
  podTemplate:
    spec: # This is a pod template specification. See https://kubernetes.io/docs/concepts/workloads/pods/#pod-templates
      containers:
        - env:
            - name: MY_VAR
              value: "my-value"
          resources:
            limits:
              cpu: 200m
              memory: 1Gi
            requests:
              cpu: 200m
              memory: 2Gi
          volumeMounts:
            - mountPath: /app/.cache/bakeware/
              name: bakeware-cache
      volumes:
        - name: bakeware-cache
          emptyDir: {}
```

When `spec.scheduling.priority` maps to one of the built-in flame classes,
the operator ensures the `PriorityClass` exists using create-if-not-exists
semantics (`flame-low`, `flame-normal`, `flame-high`, `flame-critical`).

Then:

```sh
kubectl apply -f my-runner.yaml
```

You can inspect how the operator translated high-level scheduling intent:

```sh
kubectl get flamepool my-runner-pool -n default -o yaml
```

Look for:

- `status.resolvedScheduling`
- `status.schedulingFeedback`
- `status.conditions` with `SchedulingResolved` and `SchedulingInfrastructure`

You can also read quick scheduling feedback directly from list columns:

```sh
kubectl get flamepools -A
```

Columns include `InfraReady` and `MatchingNodes` (node count).

To follow the actual runner pods created by the controller, inspect the `FlameRunner` CRDs directly:

```sh
kubectl get runners -A
kubectl get flamerunners -A
kubectl describe flamerunner <runner-name> -n <namespace>
```

This gives you a higher-level view of each runner lifecycle: whether the controller has resolved scheduling, created the pod, and whether the pod has reached a healthy or terminal state. In practice, the `status` field of a `FlameRunner` is the source of truth for the runner lifecycle, while `status.conditions` is the easiest place to understand what the controller has already validated.

Common things to look for:

- `status.phase` or similar lifecycle state such as `Pending`, `Running`, `Succeeded`, `Failed`, or `Terminating`
- `status.conditions` with entries like `Ready`, `SchedulingResolved`, `InfrastructureReady`, `PodCreated`, or `RunnerReady`
- `status.message` and `status.reason` when the controller reports why a runner could not be scheduled or started
- `metadata.name` + `metadata.namespace` to correlate the CRD with the underlying Kubernetes pod

If a runner is stuck, inspect the CRD and then the underlying pod: `kubectl get pod -n <namespace> -l flame.org/runner=<runner-name>` or `kubectl logs <pod-name> -n <namespace>` when the pod exists.

Once this is done, simply add the annotation `flame.org/pool-config-ref` to your Deployment file. Example:

```yaml
# my-application.yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flame-parent-example
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: flame-parent-example
  template:
    metadata:
      annotations:
        flame.org/enabled: "true"
        flame.org/pool-config-ref: "my-runner-pool"
    spec:
      containers:
        - image: eigr/flame-parent-example:1.1.1
...        
```

You can also list all Runner pools configured on the system with the command:

```sh
kubectl --all-namespaces get pools
```

The controller also defines a default Pool which in turn has the following configuration:

```yaml
---
apiVersion: flame.org/v1
kind: FlamePool
metadata:
  name: default-pool
  namespace: flame
spec:
  podTemplate:
    spec:
      containers:
        - env:
          - name: PHX_SERVER
            value: "false"
          - name: MIX_ENV
            value: prod
          - name: POD_NAME
            valueFrom:
              fieldRef:
                fieldPath: metadata.name
          - name: POD_NAMESPACE
            valueFrom:
              fieldRef:
                fieldPath: metadata.namespace
          - name: POD_IP
            valueFrom:
              fieldRef:
                fieldPath: status.podIP
          # Other vars...
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
```

### Compatibility and validation

The operator and runtime image are currently validated on the following Kubernetes environments and architecture:

| Environment | Status | Supported architecture |
| ---         | ---    | ---                    |
| Kind        | Tested | amd64                  |
| EKS         | Tested | amd64                  |

This project is currently validated for `amd64`. Support for other architectures is planned and will be added in upcoming releases as validation expands.