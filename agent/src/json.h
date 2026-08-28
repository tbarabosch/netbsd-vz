#ifndef NVZA_JSON_H
#define NVZA_JSON_H

#include <stddef.h>
#include <stdint.h>

enum nvza_json_type {
	NVZA_JSON_UNDEFINED = 0,
	NVZA_JSON_OBJECT,
	NVZA_JSON_ARRAY,
	NVZA_JSON_STRING,
	NVZA_JSON_PRIMITIVE
};

struct nvza_json_token {
	enum nvza_json_type type;
	int start;
	int end;
	int parent;
	int children;
};

int nvza_json_parse(const char *, size_t, struct nvza_json_token *, size_t);
int nvza_json_object_get(const char *, const struct nvza_json_token *, int,
    const char *);
int nvza_json_array_get(const struct nvza_json_token *, int, int);
int nvza_json_token_equals(const char *, const struct nvza_json_token *,
    const char *);
char *nvza_json_string_dup(const char *, const struct nvza_json_token *);
int nvza_json_uint64(const char *, const struct nvza_json_token *, uint64_t *);
int nvza_json_int64(const char *, const struct nvza_json_token *, int64_t *);
int nvza_json_bool(const char *, const struct nvza_json_token *, int *);

#endif
