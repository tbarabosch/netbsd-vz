#include "../src/json.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int
main(void)
{
	const char *json = "{\"operation\":\"create\",\"process\":{\"arguments\":[\"one two\",\"x=$(id)\"],\"uid\":42,\"terminal\":true}}";
	struct nvza_json_token tokens[64] = {{0}};
	uint64_t uid;
	int64_t signal_number;
	char *argument;
	int count, process, arguments, terminal, signal_token, path_token;

	count = nvza_json_parse(json, strlen(json), tokens, 64);
	assert(count > 0);
	assert(nvza_json_token_equals(json,
	    &tokens[nvza_json_object_get(json, tokens, 0, "operation")], "create"));
	process = nvza_json_object_get(json, tokens, 0, "process");
	arguments = nvza_json_object_get(json, tokens, process, "arguments");
	argument = nvza_json_string_dup(json,
	    &tokens[nvza_json_array_get(tokens, arguments, 1)]);
	assert(argument != NULL && strcmp(argument, "x=$(id)") == 0);
	free(argument);
	assert(nvza_json_uint64(json,
	    &tokens[nvza_json_object_get(json, tokens, process, "uid")], &uid) == 0);
	assert(uid == 42);
	assert(nvza_json_bool(json,
	    &tokens[nvza_json_object_get(json, tokens, process, "terminal")], &terminal) == 0);
	assert(terminal == 1);

	json = "{\"operation\":\"signal\",\"signal\":15}";
	memset(tokens, 0, sizeof(tokens));
	count = nvza_json_parse(json, strlen(json), tokens, 64);
	assert(count > 0);
	signal_token = nvza_json_object_get(json, tokens, 0, "signal");
	assert(signal_token >= 0);
	assert(nvza_json_int64(json, &tokens[signal_token], &signal_number) == 0);
	assert(signal_number == 15);

	json = "{\"path\":\"tmp\\u0000escape\"}";
	memset(tokens, 0, sizeof(tokens));
	count = nvza_json_parse(json, strlen(json), tokens, 64);
	assert(count > 0);
	path_token = nvza_json_object_get(json, tokens, 0, "path");
	assert(path_token >= 0);
	assert(nvza_json_string_dup(json, &tokens[path_token]) == NULL);
	puts("agent JSON tests passed");
	return 0;
}
