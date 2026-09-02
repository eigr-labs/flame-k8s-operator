version=1.1.1
registry=eigr

image=${registry}/flame-parent-example:${version}

.PHONY: all

all: clean-all build build-image create-kind-cluster create-k8s-namespace load-kind-images apply-k8s-manifests

clean:
	mix deps.clean --all

clean-all:
	mix deps.clean --all && kind delete cluster --name flame-cluster

build:
	mix deps.get && mix compile

build-image:
	docker build --no-cache -f Dockerfile -t ${image} .

push-all-images:
	docker push ${image}

create-kind-cluster:
	kind create cluster -v 1 --name flame-cluster --config kind-cluster.yaml
	kubectl cluster-info --context kind-flame-cluster

load-kind-images:
	kind load docker-image ${image} --name flame-cluster

create-k8s-namespace:
	kubectl create ns flame

apply-k8s-manifests:
	kubectl -n flame apply -f .k8s/pool.yaml
	kubectl -n flame apply -f .k8s/deployment.yaml