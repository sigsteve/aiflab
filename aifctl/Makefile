SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

BIN_DIR ?= $(CURDIR)/bin

.PHONY: build
build: fmt vet ## Build aifctl.
	mkdir -p $(BIN_DIR)
	go build -o $(BIN_DIR)/aifctl ./cmd/aifctl

.PHONY: test
test: ## Run the aifctl test suite.
	go test ./...

.PHONY: fmt
fmt: ## Format the aifctl source.
	go fmt ./...

.PHONY: vet
vet: ## Run static checks against aifctl.
	go vet ./...
