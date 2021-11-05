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
VERSION=$(or $(shell git tag -l --points-at HEAD), SNAPSHOT)


# HELP
# This will output the help for each task
# thanks to https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html
.PHONY: help

help: ## This help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.DEFAULT_GOAL := help


# DOCKER TASKS
# Build the container
build: ## Build the container
	docker build $(DOCKER_BUILD_ARGS) -t $(IMAGE):$(VERSION) $(DOCKER_BUILD_CONTEXT) -f $(DOCKER_FILE_PATH)

release: build push ## Make a release by building and pushing the `{version}` and `latest` tagged containers to Container Registry (CR)

# Docker push
push: registry-login tag ## Publish the `{version}` and `latest` tagged containers to CR
	docker push $(IMAGE):$(VERSION)
	docker push $(IMAGE):latest

# Docker tagging
tag: ## Generate container tags for the `{version}` and `latest` tags
	docker tag $(IMAGE):$(VERSION) $(IMAGE):latest


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
