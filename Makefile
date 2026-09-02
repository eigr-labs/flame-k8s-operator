version ?= 0.1.0
registry ?= ghcr.io/eigr-labs
cluster_name ?= flame-local
kind_config ?= examples/flame_example/kind-cluster.yml
operator_namespace ?= flame
example_image ?= eigr/flame-parent-example:1.1.1

operator-image = ${registry}/flame-k8s-controller:${version}

.PHONY: help preflight-local test-workspace build-operator-image build-example-image push-operator-image create-kind-cluster delete-kind-cluster load-kind-images generate-k8s-manifests apply-k8s-manifests apply-crd-examples apply-example-app wait-operator validate-local-install local-e2e local-reset

help:
	@echo "Targets:"
	@echo "  test-workspace        - Run tests for flame_k8s, flame_k8s_controller and examples/flame_example"
	@echo "  build-operator-image  - Build operator image (${operator-image})"
	@echo "  build-example-image   - Build example app image (${example_image})"
	@echo "  generate-k8s-manifests- Generate install manifests using ${operator-image}"
	@echo "  preflight-local       - Validate required local tools (docker, kubectl, kind)"
	@echo "  local-e2e             - End-to-end local validation before publish"
	@echo "  local-reset           - Remove local kind cluster"

preflight-local:
	@command -v docker >/dev/null 2>&1 || { echo "docker is required but was not found in PATH"; exit 1; }
	@command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but was not found in PATH"; exit 1; }
	@command -v kind >/dev/null 2>&1 || { echo "kind is required but was not found in PATH"; echo "Install: https://kind.sigs.k8s.io/docs/user/quick-start/#installation"; exit 1; }
	@test -f ${kind_config} || { echo "kind config not found: ${kind_config}"; exit 1; }

test-workspace:
	cd flame_k8s && MIX_ENV=test mix deps.get && MIX_ENV=test mix test
	cd flame_k8s_controller && MIX_ENV=test mix deps.get && MIX_ENV=test mix test
	cd examples/flame_example && MIX_ENV=test mix deps.get && MIX_ENV=test mix test

build-operator-image:
	docker build --no-cache -f flame_k8s_controller/Dockerfile-operator -t ${operator-image} flame_k8s_controller

build-example-image:
	docker build --no-cache -f examples/flame_example/Dockerfile -t ${example_image} .

push-operator-image:
	docker push ${operator-image}

create-kind-cluster:
	kind create cluster -v 1 --name ${cluster_name} --config ${kind_config}
	kubectl cluster-info --context kind-${cluster_name}

delete-kind-cluster:
	kind delete cluster --name ${cluster_name}

load-kind-images:
	kind load docker-image ${operator-image} --name ${cluster_name}
	kind load docker-image ${example_image} --name ${cluster_name}

generate-k8s-manifests:
	cd flame_k8s_controller && MIX_ENV=prod mix deps.get && MIX_ENV=prod mix flame.gen.manifest --image ${operator-image} --namespace ${operator_namespace} --out ../.k8s/install/manifests

apply-k8s-manifests:
	kubectl apply -f .k8s/install/manifests/flamepool.crd.yaml
	kubectl apply -f .k8s/install/manifests/flamerunner.crd.yaml
	kubectl wait --for=condition=Established crd/flamepools.flame.org --timeout=60s
	kubectl wait --for=condition=Established crd/flamerunners.flame.org --timeout=60s
	kubectl apply -k .k8s/install/manifests

apply-crd-examples:
	kubectl apply -f examples/crds/flamepool-apply.yaml
	kubectl apply -f examples/crds/flamerunner-apply.yaml

apply-example-app:
	kubectl apply -f examples/flame_example/.k8s/pool.yaml
	kubectl apply -f examples/flame_example/.k8s/deployment.yaml

wait-operator:
	kubectl -n ${operator_namespace} rollout status deployment/flame-controller --timeout=120s

validate-local-install:
	kubectl get crd flamepools.flame.org flamerunners.flame.org
	kubectl -n ${operator_namespace} get deploy flame-controller
	kubectl -A get flamepools
	kubectl -A get flamerunners
	kubectl -n default get deploy flame-parent-example

local-e2e:
	$(MAKE) preflight-local
	$(MAKE) test-workspace
	$(MAKE) build-operator-image version=dev-local
	$(MAKE) build-example-image
	$(MAKE) create-kind-cluster
	$(MAKE) load-kind-images version=dev-local
	$(MAKE) generate-k8s-manifests version=dev-local
	$(MAKE) apply-k8s-manifests
	$(MAKE) wait-operator
	$(MAKE) apply-crd-examples
	$(MAKE) apply-example-app
	$(MAKE) validate-local-install

local-reset:
	$(MAKE) delete-kind-cluster