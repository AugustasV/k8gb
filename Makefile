# Copyright 2021 The k8gb Contributors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Generated by GoLic, for more details see: https://github.com/AbsaOSS/golic
###############################
#       DOTENV
###############################
ifneq ($(wildcard ./.env),)
	include .env
	export
endif

###############################
#		CONSTANTS
###############################
CLUSTER_GSLB1 = test-gslb1
CLUSTER_GSLB2 = test-gslb2
CLUSTER_GSLB_NETWORK = k3d-action-bridge-network
GSLB_DOMAIN ?= cloud.example.com
REPO = absaoss/k8gb
VALUES_YAML ?= chart/k8gb/values.yaml
PODINFO_IMAGE_REPO ?= ghcr.io/stefanprodan/podinfo
HELM_ARGS ?=
K8GB_COREDNS_IP ?= kubectl get svc k8gb-coredns -n k8gb -o custom-columns='IP:spec.clusterIP' --no-headers
CLUSTER_GSLB2_HELM_ARGS ?= --set k8gb.clusterGeoTag='us' --set k8gb.extGslbClustersGeoTags='eu' --set k8gb.hostAlias.hostnames='{gslb-ns-eu-cloud.example.com}'
LOG_FORMAT ?= simple
LOG_LEVEL ?= debug
CONTROLLER_GEN_VERSION  ?= v0.4.1
GOLIC_VERSION  ?= v0.5.0
POD_NAMESPACE ?= k8gb
CLUSTER_GEO_TAG ?= eu
EXT_GSLB_CLUSTERS_GEO_TAGS ?= us
EDGE_DNS_SERVER ?= 1.1.1.1
EDGE_DNS_ZONE ?= example.com
DNS_ZONE ?= cloud.example.com

ifndef NO_COLOR
YELLOW=\033[0;33m
CYAN=\033[1;36m
# no color
NC=\033[0m
endif

NO_VALUE ?= no_value

###############################
#		VARIABLES
###############################
PWD ?=  $(shell pwd)
VERSION ?= $(shell helm show chart chart/k8gb/|awk '/appVersion:/ {print $$2}')
COMMIT_HASH ?= $(shell git rev-parse --short HEAD)
SEMVER ?= $(VERSION)-$(COMMIT_HASH)
# image URL to use all building/pushing image targets
IMG ?= $(REPO):$(VERSION)
STABLE_VERSION := "stable"
# default bundle image tag
BUNDLE_IMG ?= controller-bundle:$(VERSION)

# options for 'bundle-build'
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

# create GOBIN if not specified
ifndef GOBIN
GOBIN=$(shell go env GOPATH)/bin
endif

###############################
#		TARGETS
###############################

all: help

.PHONY: clean-test-apps
clean-test-apps:
	kubectl delete -f deploy/test-apps
	helm -n test-gslb uninstall backend
	helm -n test-gslb uninstall frontend

# see: https://dev4devs.com/2019/05/04/operator-framework-how-to-debug-golang-operator-projects/
.PHONY: debug-idea
debug-idea: export WATCH_NAMESPACE=test-gslb
debug-idea:
	$(call debug,debug --headless --listen=:2345 --api-version=2)

.PHONY: demo-roundrobin
demo-roundrobin: ## Execute round-robin demo
	@$(call demo-host, "roundrobin.cloud.example.com")

.PHONY: demo-failover
demo-failover: ## Execute failover demo
	@$(call demo-host, "failover.cloud.example.com")


# spin-up local environment
.PHONY: deploy-full-local-setup
deploy-full-local-setup: ## Deploy full local multicluster setup (k3d >= 4.2.0)
	$(call create-local-cluster,$(CLUSTER_GSLB1))
	$(call create-local-cluster,$(CLUSTER_GSLB2))

	$(call deploy-local-cluster,$(CLUSTER_GSLB1),$(CLUSTER_GSLB2),$(VERSION),,'k8gb/k8gb')
	$(call deploy-local-cluster,$(CLUSTER_GSLB2),$(CLUSTER_GSLB1),$(VERSION),$(CLUSTER_GSLB2_HELM_ARGS),'k8gb/k8gb')

.PHONY: deploy-stable
deploy-stable:
	@echo "\n$(YELLOW) import $(CYAN)k8gb:$(STABLE_VERSION) $(YELLOW)to $(CYAN)$(CLUSTER_GSLB1), $(CLUSTER_GSLB2) $(NC)"
	$(call deploy-local-cluster,$(CLUSTER_GSLB1),$(CLUSTER_GSLB2),$(STABLE_VERSION),,'k8gb/k8gb')
	$(call deploy-local-cluster,$(CLUSTER_GSLB2),$(CLUSTER_GSLB1),$(STABLE_VERSION),$(CLUSTER_GSLB2_HELM_ARGS),'k8gb/k8gb')

	$(call list-running-pods,$(CLUSTER_GSLB1))
	$(call list-running-pods,$(CLUSTER_GSLB2))

.PHONY: upgrade-candidate
upgrade-candidate: ## Upgrade k8gb to the test version on existing clusters
	@echo "\n$(YELLOW)build k8gb docker and import to $(CYAN)$(CLUSTER_GSLB1), $(CLUSTER_GSLB2) $(NC)"
	docker build . -t $(REPO):$(SEMVER)

	k3d image import $(REPO):$(SEMVER) -c $(CLUSTER_GSLB1)
	k3d image import $(REPO):$(SEMVER) -c $(CLUSTER_GSLB2)

	@echo "\n$(YELLOW)Upgrade GSLB operator from $(STABLE_VERSION) to $(SEMVER) on k3d-$(CLUSTER_GSLB1) $(NC)"
	kubectl config use-context k3d-$(CLUSTER_GSLB1)
	$(call deploy-k8gb-with-helm,$(CLUSTER_GSLB1),$(CLUSTER_GSLB2),$(SEMVER),,'./chart/k8gb')

	@echo "\n$(YELLOW)Upgrade GSLB operator from $(STABLE_VERSION) to $(SEMVER) on k3d-$(CLUSTER_GSLB2) $(NC)"
	kubectl config use-context k3d-$(CLUSTER_GSLB2)
	$(call deploy-k8gb-with-helm,$(CLUSTER_GSLB2),$(CLUSTER_GSLB1),$(SEMVER),$(CLUSTER_GSLB2_HELM_ARGS),'./chart/k8gb')

	$(call list-running-pods,$(CLUSTER_GSLB1))
	$(call list-running-pods,$(CLUSTER_GSLB2))

.PHONY: deploy-candidate
deploy-candidate: ## Deploy test k8gb version together with CRs and test apps on top of existing clusters
	@echo "\n$(YELLOW)build k8gb docker and import to $(CYAN)$(CLUSTER_GSLB1), $(CLUSTER_GSLB2) $(NC)"
	docker build . -t $(REPO):$(SEMVER)

	k3d image import $(REPO):$(SEMVER) -c $(CLUSTER_GSLB1)
	k3d image import $(REPO):$(SEMVER) -c $(CLUSTER_GSLB2)

	$(call deploy-local-cluster,$(CLUSTER_GSLB1),$(CLUSTER_GSLB2),$(SEMVER),,'./chart/k8gb')
	$(call deploy-local-cluster,$(CLUSTER_GSLB2),$(CLUSTER_GSLB1),$(SEMVER),$(CLUSTER_GSLB2_HELM_ARGS),'./chart/k8gb')

	$(call list-running-pods,$(CLUSTER_GSLB1))
	$(call list-running-pods,$(CLUSTER_GSLB2))

.PHONY: deploy-gslb-operator
deploy-gslb-operator: ## Deploy k8gb operator
	kubectl apply -f deploy/namespace.yaml
	cd chart/k8gb && helm dependency update
	helm -n k8gb upgrade -i k8gb chart/k8gb -f $(VALUES_YAML) $(HELM_ARGS) \
		--set k8gb.log.format=$(LOG_FORMAT)
		--set k8gb.log.level=$(LOG_LEVEL)

.PHONY: deploy-gslb-cr
deploy-gslb-cr: ## Apply Gslb Custom Resources
	kubectl apply -f deploy/crds/test-namespace.yaml
	$(call apply-cr,deploy/crds/k8gb.absa.oss_v1beta1_gslb_cr.yaml)
	$(call apply-cr,deploy/crds/k8gb.absa.oss_v1beta1_gslb_cr_failover.yaml)

.PHONY: deploy-test-apps
deploy-test-apps: ## Deploy testing workloads
	kubectl apply -f deploy/crds/test-namespace.yaml
	$(call deploy-test-apps)

# destroy local test environment
.PHONY: destroy-full-local-setup
destroy-full-local-setup: ## Destroy full local multicluster setup
	k3d cluster delete $(CLUSTER_GSLB1)
	k3d cluster delete $(CLUSTER_GSLB2)
	docker network rm $(CLUSTER_GSLB_NETWORK)

.PHONY: dns-tools
dns-tools: ## Run temporary dnstools pod for debugging DNS issues
	@kubectl -n k8gb get svc k8gb-coredns
	@kubectl -n k8gb run -it --rm --restart=Never --image=infoblox/dnstools:latest dnstools

.PHONY: dns-smoke-test
dns-smoke-test:
	kubectl -n k8gb run -it --rm --restart=Never --image=infoblox/dnstools:latest dnstools --command -- /usr/bin/dig @k8gb-coredns roundrobin.cloud.example.com

# build docker images for multiple architectures
# useful for CI
.PHONY: docker-build-multi
docker-build-multi: test
	$(call docker-build-arch,amd64)
	$(call docker-build-arch,arm64)

# push docker for multiple architectures
.PHONY: docker-push-multi
docker-push-multi:
	$(call docker-push-arch,amd64)
	$(call docker-push-arch,arm64)

# create and push docker manifest
.PHONY: docker-manifest
docker-manifest: docker-push-multi
	docker manifest create ${IMG} \
		${IMG}-amd64 \
		${IMG}-arm64
	docker manifest annotate ${IMG} ${IMG}-arm64 \
		--os linux --arch arm64
	docker manifest push ${IMG}

# build the docker image
.PHONY: docker-build
docker-build: test
	$(call docker-build-arch,amd64)

# push the docker image
.PHONY: docker-push
docker-push:
	$(call docker-push-arch,amd64)

# build and push the docker image exclusively for testing using commit hash
.PHONY: docker-test-build-push
docker-test-build-push: test
	$(call docker-test-build-push)

.PHONY: init-failover
init-failover:
	$(call init-test-strategy, "deploy/crds/k8gb.absa.oss_v1beta1_gslb_cr_failover.yaml")

.PHONY: init-round-robin
init-round-robin:
	$(call init-test-strategy, "deploy/crds/k8gb.absa.oss_v1beta1_gslb_cr.yaml")

# creates infoblox secret in current cluster
.PHONY: infoblox-secret
infoblox-secret:
	kubectl -n k8gb create secret generic infoblox \
		--from-literal=EXTERNAL_DNS_INFOBLOX_WAPI_USERNAME=$${WAPI_USERNAME} \
		--from-literal=EXTERNAL_DNS_INFOBLOX_WAPI_PASSWORD=$${WAPI_PASSWORD}

# updates source code with license headers
.PHONY: license
license:
	$(call golic,-t apache2)

# creates ns1 secret in current cluster
.PHONY: ns1-secret
ns1-secret:
	kubectl -n k8gb create secret generic ns1 \
		--from-literal=apiKey=$${NS1_APIKEY}


# runs golangci-lint aggregated linter; see .golangci.yaml for linter list
.PHONY: lint
lint:
	golangci-lint run

# retrieves all targets
.PHONY: list
list:
	@$(MAKE) -pRrq -f $(lastword $(MAKEFILE_LIST)) : 2>/dev/null | awk -v RS= -F: '/^# File/,/^# Finished Make data base/ {if ($$1 !~ "^[#.]") {print $$1}}' | sort | egrep -v -e '^[^[:alnum:]]' -e '^$@$$'

# build manager binary
.PHONY: manager
manager: lint
	$(call generate)
	go build -o bin/manager main.go

.PHONY: mocks
mocks:
	go install github.com/golang/mock/mockgen@v1.5.0
	mockgen -source=controllers/providers/assistant/iassistant.go -destination=controllers/providers/assistant/assistant_mock.go -package=assistant
	$(call golic)

# remove clusters and redeploy
.PHONY: reset
reset:	destroy-full-local-setup deploy-full-local-setup

# run against the configured Kubernetes cluster in ~/.kube/config
.PHONY: run
run: lint
	$(call generate)
	$(call manifest)
	LOG_FORMAT=$(LOG_FORMAT) \
	LOG_LEVEL=$(LOG_LEVEL) \
	POD_NAMESPACE=$(POD_NAMESPACE) \
	CLUSTER_GEO_TAG=$(CLUSTER_GEO_TAG) \
	EXT_GSLB_CLUSTERS_GEO_TAGS=$(EXT_GSLB_CLUSTERS_GEO_TAGS) \
	EDGE_DNS_SERVER=$(EDGE_DNS_SERVER) \
	EDGE_DNS_ZONE=$(EDGE_DNS_ZONE) \
	DNS_ZONE=$(DNS_ZONE) \
	go run ./main.go

.PHONY: stop-test-app
stop-test-app:
	$(call testapp-set-replicas,0)

.PHONY: start-test-app
start-test-app:
	$(call testapp-set-replicas,2)

# run tests
.PHONY: test
test: license lint
	$(call generate)
	$(call manifest)
	go test ./... -coverprofile cover.out

.PHONY: test-round-robin
test-round-robin:
	@$(call hit-testapp-host, "roundrobin.cloud.example.com")

.PHONY: test-failover
test-failover:
	@$(call hit-testapp-host, "failover.cloud.example.com")

# executes terra-tests
.PHONY: terratest
terratest: # Run terratest suite
	cd terratest/test/ && go mod download && go test -v -timeout 15m -parallel=12

.PHONY: version
version:
	@echo $(VERSION)

.PHONY: help
help: ## Show this help
	@egrep -h '\s##\s' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

###############################
#		FUNCTIONS
###############################

define create-local-cluster
	@echo "\n$(YELLOW)Deploy local cluster $(CYAN)$1 $(NC)"
	k3d cluster create -c k3d/$1.yaml
endef

define deploy-k8gb-with-helm
	helm repo add --force-update k8gb https://www.k8gb.io
	cd chart/k8gb && helm dependency update
	helm -n k8gb upgrade -i k8gb $5 -f $(VALUES_YAML) \
		--set k8gb.hostAlias.enabled=true \
		--set k8gb.hostAlias.ip="`$(call get-host-alias-ip,k3d-$1,k3d-$2)`" \
		--set k8gb.imageTag=$3 $4 \
		--set k8gb.log.format=$(LOG_FORMAT) \
		--set k8gb.log.level=$(LOG_LEVEL) \
		--wait --timeout=2m0s
endef

define deploy-local-cluster
	@echo "\n$(YELLOW)Local cluster $(CYAN)$1 $(NC)"
	kubectl config use-context k3d-$1

	@echo "\n$(YELLOW)Create namespace $(NC)"
	kubectl apply -f deploy/namespace.yaml

	@echo "\n$(YELLOW)Deploy GSLB operator from ${3} $(NC)"
	$(call deploy-k8gb-with-helm,$1,$2,${3:"stable"=""},$4,$5)

	@echo "\n$(YELLOW)Deploy Ingress $(NC)"
	helm repo add --force-update nginx-stable https://kubernetes.github.io/ingress-nginx
	helm repo update
	helm -n k8gb upgrade -i nginx-ingress nginx-stable/ingress-nginx \
		--version 3.24.0 -f deploy/ingress/nginx-ingress-values.yaml

	@echo "\n$(YELLOW)Deploy GSLB cr $(NC)"
	kubectl apply -f deploy/crds/test-namespace.yaml
	$(call apply-cr,deploy/crds/k8gb.absa.oss_v1beta1_gslb_cr.yaml)
	$(call apply-cr,deploy/crds/k8gb.absa.oss_v1beta1_gslb_cr_failover.yaml)

	@echo "\n$(YELLOW)Deploy test apps $(NC)"
	$(call deploy-test-apps)

	@echo "\n$(YELLOW)Wait until Ingress controller is ready $(NC)"
	$(call wait-for-ingress)

	@echo "\n$(CYAN)$1 $(YELLOW)deployed! $(NC)"
endef

define apply-cr
	sed -i 's/cloud\.example\.com/$(GSLB_DOMAIN)/g' "$1"
	kubectl apply -f "$1"
	git checkout -- "$1"
endef

define deploy-test-apps
	kubectl apply -f deploy/test-apps
	helm repo add podinfo https://stefanprodan.github.io/podinfo
	helm upgrade --install frontend --namespace test-gslb -f deploy/test-apps/podinfo/podinfo-values.yaml \
		--set ui.message="`$(call get-cluster-geo-tag)`" \
		--set image.repository="$(PODINFO_IMAGE_REPO)" \
		podinfo/podinfo
endef

define get-cluster-geo-tag
	kubectl -n k8gb describe deploy k8gb |  awk '/CLUSTER_GEO_TAG/ { printf $$2 }'
endef

# get-host-alias-ip switch to second context ($2), search for IP and switch back to first context ($1)
# function returns one IP address
define get-host-alias-ip
	kubectl config use-context $2 > /dev/null && \
	kubectl get nodes $2-agent-0 -o custom-columns='IP:status.addresses[0].address' --no-headers && \
	kubectl config use-context $1 > /dev/null
endef

define hit-testapp-host
	kubectl run -it --rm busybox --restart=Never --image=busybox -- sh -c \
	"echo 'nameserver `$(K8GB_COREDNS_IP)`' > /etc/resolv.conf && \
	wget -qO - $1"
endef

define init-test-strategy
 	kubectl config use-context k3d-test-gslb2
 	kubectl apply -f $1
 	kubectl config use-context k3d-test-gslb1
 	kubectl apply -f $1
 	$(call testapp-set-replicas,2)
endef

define testapp-set-replicas
	kubectl scale deployment frontend-podinfo -n test-gslb --replicas=$1
endef

define demo-host
	kubectl run -it --rm k8gbdemo --restart=Never --image=absaoss/k8gbdemocurl  \
	"`$(K8GB_COREDNS_IP)`" $1
endef

# waits for NGINX, GSLB are ready
define wait-for-ingress
	kubectl -n k8gb wait --for=condition=Ready pod -l app.kubernetes.io/name=ingress-nginx --timeout=600s
endef

define generate
	$(call controller-gen,object:headerFile="hack/boilerplate.go.txt" paths="./...")
endef

define manifest
	$(call controller-gen,crd:crdVersions=v1 paths="./..." output:crd:artifacts:config=chart/k8gb/templates/crds)
endef

define controller-gen
	@go install sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_GEN_VERSION)
	$(GOBIN)/controller-gen $1
endef

define golic
	@go install github.com/AbsaOSS/golic@$(GOLIC_VERSION)
	$(GOBIN)/golic inject $1
endef

define docker-build-arch
	docker build --build-arg GOARCH=${1} -t ${IMG}-${1} .
endef

define docker-push-arch
	docker push ${IMG}-${1}
endef

define docker-test-build-push
	docker build . -t k8gb:$(COMMIT_HASH)
	docker tag k8gb:$(COMMIT_HASH) $(REPO):$(COMMIT_HASH)
	docker push $(REPO):$(COMMIT_HASH)
	sed -i "s/$(VERSION)/$(COMMIT_HASH)/g" chart/k8gb/Chart.yaml
endef

define debug
	$(call manifest)
	kubectl apply -f deploy/crds/test-namespace.yaml
	kubectl apply -f ./chart/k8gb/templates/k8gb.absa.oss_gslbs.yaml
	kubectl apply -f ./deploy/crds/k8gb.absa.oss_v1beta1_gslb_cr.yaml
	dlv $1
endef

define list-running-pods
	@echo "\n$(YELLOW)Local cluster $(CYAN)$1 $(NC)"
	kubectl get pods -A --context=k3d-$1
endef
