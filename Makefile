SHELL := /bin/sh

DISK ?= $(CURDIR)/.build/out/netbsd-vz.raw

.DEFAULT_GOAL := build

.PHONY: build disk platform-kit run run-network clean

build:
	./scripts/build.sh

disk:
	./scripts/build-disk.sh

platform-kit: build
	./scripts/build-platform-kit.sh

run:
	./scripts/run.sh --disk "$(DISK)"

run-network:
	./scripts/run.sh --disk "$(DISK)" --network

clean:
	./scripts/clean.sh
