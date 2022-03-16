# MAIN VARS
#
# Import deploy config (change w/ `make dpl="deploy_special.env" release`)
dpl ?= deploy.env
ifneq ($(wildcard $(dpl)),)
include $(dpl)
export $(shell sed 's/=.*//' $(dpl))
endif

# Recipe vars
USERNAME=$(USER)
NAME=flink
IMAGE=$(REGISTRY_HOST)/$(USERNAME)/$(NAME)
DOCKER_BUILD_CONTEXT=.
DOCKER_FILE_PATH=Dockerfile
GIT_TAG=$(shell git tag -l --points-at HEAD)
VERSION=$(or $(GIT_TAG), SNAPSHOT)
MINOR_VERSION=$(shell echo $(VERSION) | cut -d '.' -f 2,3 | sed 's/-SNAPSHOT.*//g')
DOCKER_BUILD_TARGET=$(if $(findstring SNAPSHOT, $(VERSION)),snapshot,stable)
COMMIT=$(shell echo $(GIT_TAG) | cut -d '-' -f 3)


# HELP
# This will output the help for each task
# thanks to https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html
.PHONY: help release build push clear-builder tag registry-login version

help: ## This help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.DEFAULT_GOAL := help


release: build push ## Make a release by building and pushing the `{version}` and `latest` tagged containers to Container Registry (CR)


# DOCKER TASKS
# Build the container
build: ## Build the container
	$(eval BUILDER := $(shell docker buildx create \
		--driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=10000000 \
		--driver-opt env.BUILDKIT_STEP_LOG_MAX_SPEED=10000000))
	docker buildx build --builder $(BUILDER) \
		-t $(IMAGE):$(VERSION) \
		-o type=docker \
		$$(./get-dependencies.sh $(VERSION)) \
		--build-arg FLINK_COMMIT=$(COMMIT) \
		--build-arg FLINK_VERSION=$(VERSION) $(DOCKER_BUILD_ARGS) \
		--build-arg FLINK_MINOR_VERSION=$(MINOR_VERSION) \
		--target flink_$(DOCKER_BUILD_TARGET) \
		$(DOCKER_BUILD_CONTEXT) -f $(DOCKER_FILE_PATH) \
		--progress plain

# Docker push
push: registry-login ## Publish the `{version}` and `latest` tagged containers to CR
	$(MAKE) tag
	docker push $(IMAGE):$(VERSION)
ifeq ($(DOCKER_BUILD_TARGET),stable)
	docker push $(IMAGE):latest
endif
	$(MAKE) clear-builder

# Clear builder instance
clear-builder: ## Clear builder instance
	docker buildx rm $(BUILDER)

# Docker tagging
tag: ## Generate container tags for the `latest` tag
ifeq ($(DOCKER_BUILD_TARGET),stable)
	docker tag $(IMAGE):$(VERSION) $(IMAGE):latest
endif


# HELPERS
# Generate script to login to aws docker repo
CMD_REPOLOGIN := "eval $$\( aws ecr"
ifdef AWS_CLI_PROFILE
CMD_REPOLOGIN += " --profile $(AWS_CLI_PROFILE)"
endif
ifdef AWS_CLI_REGION
CMD_REPOLOGIN += " --region $(AWS_CLI_REGION)"
endif
CMD_REPOLOGIN += " get-login --no-include-email \)"

# Login to CR
registry-login-aws: ## Auto login to AWS-ECR using aws-cli
	@eval $(CMD_REPOLOGIN)

ifdef AWS_CLI_PROFILE
registry-login: registry-login-aws
endif

registry-login: ## Login to Docker Hub if  `{dockerhub_user}` and `{dockerhub_token}` envvars are defined
ifneq ($(DOCKERHUB_TOKEN)$(DOCKERHUB_USER),)
	docker logout
	docker login --username $(DOCKERHUB_USER) --password $(DOCKERHUB_TOKEN)
endif

version: ## Output the current version
	@echo $(VERSION)
