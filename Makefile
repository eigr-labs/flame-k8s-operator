version ?= 0.1.1
registry ?= ghcr.io/eigr-labs
cluster_name ?= flame-local
kind_config ?= examples/flame_example/kind-cluster.yml
operator_namespace ?= flame
example_image ?= eigr/flame-parent-example:1.1.2
cookie_secret_name ?= flame-erlang-cookie

operator-image = ${registry}/flame-k8s-controller:${version}

.PHONY: help preflight-local ensure-cookie-secret test-workspace build-operator-image build-example-image push-operator-image create-kind-cluster delete-kind-cluster load-kind-images generate-k8s-manifests apply-k8s-manifests restart-operator apply-crd-examples apply-example-app wait-operator wait-generated-runner validate-local-install local-e2e local-reset

help:
	@echo "Targets:"
	@echo "  test-workspace        - Run tests for flame_k8s, flame_k8s_controller and examples/flame_example"
	@echo "  build-operator-image  - Build operator image (${operator-image})"
	@echo "  build-example-image   - Build example app image (${example_image})"
	@echo "  generate-k8s-manifests- Generate install manifests using ${operator-image}"
	@echo "  preflight-local       - Validate required local tools (docker, kubectl, kind)"
	@echo "  ensure-cookie-secret  - Create/reuse the operator namespace Erlang cookie secret"
	@echo "  local-e2e             - End-to-end local validation before publish"
	@echo "  local-reset           - Remove local kind cluster"

preflight-local:
	@command -v docker >/dev/null 2>&1 || { echo "docker is required but was not found in PATH"; exit 1; }
	@command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but was not found in PATH"; exit 1; }
	@command -v kind >/dev/null 2>&1 || { echo "kind is required but was not found in PATH"; echo "Install: https://kind.sigs.k8s.io/docs/user/quick-start/#installation"; exit 1; }
	@command -v openssl >/dev/null 2>&1 || { echo "openssl is required but was not found in PATH"; exit 1; }
	@test -f ${kind_config} || { echo "kind config not found: ${kind_config}"; exit 1; }

ensure-cookie-secret:
	@test -n "${namespace}" || { echo "namespace variable is required, e.g. make ensure-cookie-secret namespace=flame"; exit 1; }
	@kubectl get namespace ${namespace} >/dev/null 2>&1 || kubectl create namespace ${namespace}
	@if kubectl -n ${namespace} get secret ${cookie_secret_name} >/dev/null 2>&1; then \
		echo "cookie secret '${cookie_secret_name}' already exists in namespace '${namespace}', reusing it"; \
	else \
		cookie=$$(openssl rand -hex 32); \
		kubectl -n ${namespace} create secret generic ${cookie_secret_name} --from-literal=cookie="$$cookie"; \
		echo "created cookie secret '${cookie_secret_name}' in namespace '${namespace}'"; \
	fi

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
	@if kind get clusters | grep -qx "${cluster_name}"; then \
		echo "kind cluster '${cluster_name}' already exists, reusing it"; \
	else \
		kind create cluster -v 1 --name ${cluster_name} --config ${kind_config}; \
	fi
	kubectl cluster-info --context kind-${cluster_name}

delete-kind-cluster:
	kind delete cluster --name ${cluster_name}

load-kind-images:
	kind load docker-image ${operator-image} --name ${cluster_name}
	kind load docker-image ${example_image} --name ${cluster_name}

generate-k8s-manifests:
	mkdir -p .k8s/install/manifests
	rm -f .k8s/install/manifests/*.yaml
	cd flame_k8s_controller && MIX_ENV=prod mix deps.get && MIX_ENV=prod mix flame.gen.manifest --image ${operator-image} --namespace ${operator_namespace} --out ../.k8s/install/manifests

apply-k8s-manifests:
	kubectl apply -f .k8s/install/manifests/namespace.yaml
	$(MAKE) ensure-cookie-secret namespace=${operator_namespace}
	kubectl apply -f .k8s/install/manifests/flamepool.crd.yaml
	kubectl apply -f .k8s/install/manifests/flamerunner.crd.yaml
	kubectl wait --for=condition=Established crd/flamepools.flame.org --timeout=60s
	kubectl wait --for=condition=Established crd/flamerunners.flame.org --timeout=60s
	kubectl apply -k .k8s/install/manifests

restart-operator:
	kubectl -n ${operator_namespace} rollout restart deployment/flame-controller

apply-crd-examples:
	kubectl apply -f examples/crds/flamepool-apply.yaml
	kubectl apply -f examples/crds/flamerunner-apply.yaml

apply-example-app:
	kubectl delete deployment flame-parent-example -n default --ignore-not-found=true
	kubectl delete flamerunners -n default -l flame.org/parent=flame-parent-example --ignore-not-found=true
	@deadline=$$(($$(date +%s) + 60)); \
	while kubectl get deployment flame-parent-example -n default >/dev/null 2>&1; do \
		if [ $$(date +%s) -ge $$deadline ]; then \
			echo "timed out waiting for flame-parent-example to be deleted"; \
			kubectl get deployment flame-parent-example -n default -o wide || true; \
			exit 1; \
		fi; \
		sleep 2; \
	done
	kubectl apply -f examples/flame_example/.k8s/pool.yaml
	kubectl create -f examples/flame_example/.k8s/deployment.yaml

wait-generated-runner:
	@namespace=default; \
	parent_label='flame.org/parent=flame-parent-example'; \
	deadline=$$(($$(date +%s) + 240)); \
	while true; do \
		runner_name=$$(kubectl -n $$namespace get flamerunners -l $$parent_label -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true); \
		if [ -n "$$runner_name" ] && kubectl -n $$namespace get pod "$$runner_name" >/dev/null 2>&1; then \
			echo "generated runner pod '$$runner_name' is present in namespace '$$namespace'"; \
			kubectl -n $$namespace get flamerunners -l $$parent_label -o wide; \
			break; \
		fi; \
		if [ $$(date +%s) -ge $$deadline ]; then \
			echo "timed out waiting for generated runner pod in namespace '$$namespace'"; \
			kubectl get flamerunners -A; \
			kubectl get pods -A; \
			exit 1; \
		fi; \
		sleep 2; \
	done

wait-operator:
	kubectl -n ${operator_namespace} rollout status deployment/flame-controller --timeout=180s || ( \
		echo "[wait-operator] rollout failed, collecting diagnostics..."; \
		kubectl -n ${operator_namespace} get deploy flame-controller; \
		kubectl -n ${operator_namespace} get pods -l k8s-app=flame-controller -o wide; \
		kubectl -n ${operator_namespace} describe deploy flame-controller | sed -n '1,220p'; \
		pod=$$(kubectl -n ${operator_namespace} get pods -l k8s-app=flame-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
		if [ -n "$$pod" ]; then \
			kubectl -n ${operator_namespace} describe pod $$pod | sed -n '1,260p'; \
			kubectl -n ${operator_namespace} logs $$pod -c init-certificates --tail=200 || true; \
			kubectl -n ${operator_namespace} logs $$pod -c flame-controller --tail=200 || true; \
		fi; \
		exit 1; \
	)

validate-local-install:
	kubectl get crd flamepools.flame.org flamerunners.flame.org
	kubectl -n ${operator_namespace} get deploy flame-controller
	kubectl get flamepools --all-namespaces
	kubectl get flamerunners --all-namespaces
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
	$(MAKE) restart-operator
	$(MAKE) wait-operator
	$(MAKE) apply-example-app
	$(MAKE) wait-generated-runner
	$(MAKE) validate-local-install

local-reset:
	$(MAKE) delete-kind-cluster