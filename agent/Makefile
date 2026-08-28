SHELL := /bin/sh

.PHONY: build test clean

build:
	../scripts/build-agent.sh

test:
	cc -std=c11 -Wall -Wextra -Werror -pedantic src/json.c tests/json_test.c -o /tmp/netbsd-vz-json-test
	/tmp/netbsd-vz-json-test

clean:
	/bin/rm -f /tmp/netbsd-vz-json-test
