SHELL := /bin/sh

IMAGE ?= $(CURDIR)/.build/out/netbsd-VZ64-vz.img
DISK ?= $(CURDIR)/.build/out/netbsd-vz-root.raw

.DEFAULT_GOAL := help

.PHONY: help build disk run run-network run-kernel smoke smoke-network clean

help:
	@printf '%s\n' \
	  'make build               Build the reduced NetBSD 11 VZ64 kernel' \
	  'make disk                Build the minimal 1 GiB GPT/FFS root disk' \
	  'make run                 Boot the kernel and a disposable root-disk clone' \
	  'make run-network         Boot the root disk with opt-in Virtio NAT' \
	  'make run-kernel          Boot the diskless kernel root-prompt regression' \
	  'make smoke               Prove login, shell execution, and guest poweroff' \
	  'make smoke-network       Prove DHCP, gateway/public ping, and guest poweroff' \
	  'make run IMAGE=... DISK=...  Boot alternate kernel/disk inputs' \
	  'make clean               Remove objects and outputs, preserving expensive caches'

build:
	./scripts/build.sh

disk:
	./scripts/build-disk.sh

run:
	./scripts/run.sh --disk "$(DISK)" "$(IMAGE)"

run-network:
	./scripts/run.sh --disk "$(DISK)" --network "$(IMAGE)"

run-kernel:
	./scripts/run.sh "$(IMAGE)"

smoke:
	./scripts/run.sh --disk "$(DISK)" --smoke "$(IMAGE)"

smoke-network:
	./scripts/run.sh --disk "$(DISK)" --network --smoke "$(IMAGE)"

clean:
	./scripts/clean.sh
