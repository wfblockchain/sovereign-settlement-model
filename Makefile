# Clearing-house settlement model — build/test helpers.
.PHONY: help test gotest economics all

help:
	@echo "  make test        forge test (contracts, via Docker)"
	@echo "  make gotest      go test ./... (optimiser + simulation)"
	@echo "  make economics   print the efficiency / accrual tables"
	@echo "  make all         everything above"

test:
	cd contracts && docker run --rm -v "$$PWD":/w -w /w ghcr.io/foundry-rs/foundry:stable "forge test"

gotest:
	go test ./... -count=1

economics:
	go run ./cmd/clearing-operator

all: gotest test economics
