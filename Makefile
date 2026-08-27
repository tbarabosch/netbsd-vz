SHELL := /bin/sh

DISK ?= $(CURDIR)/.build/out/netbsd-vz.raw

.DEFAULT_GOAL := build

.PHONY: build disk run run-network clean

build:
	./scripts/build.sh

disk:
	./scripts/build-disk.sh

run:
	./scripts/run.sh --disk "$(DISK)"

run-network:
	./scripts/run.sh --disk "$(DISK)" --network

clean:
	./scripts/clean.sh
