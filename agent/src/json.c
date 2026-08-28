#include "json.h"

#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

static int
new_token(struct nvza_json_token *tokens, size_t capacity, int *count,
    enum nvza_json_type type, int start, int parent)
{
	struct nvza_json_token *token;

	if ((size_t)*count >= capacity) {
		errno = ENOSPC;
		return -1;
	}
	token = &tokens[*count];
	token->type = type;
	token->start = start;
	token->end = -1;
	token->parent = parent;
	token->children = 0;
	if (parent >= 0)
		tokens[parent].children++;
	return (*count)++;
}

static int
hex_value(char c)
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

int
nvza_json_parse(const char *json, size_t length, struct nvza_json_token *tokens,
    size_t capacity)
{
	int count = 0, parent = -1, token, i;
	size_t pos;
	char c;

	if (json == NULL || tokens == NULL) {
		errno = EINVAL;
		return -1;
	}
	for (pos = 0; pos < length; pos++) {
		c = json[pos];
		switch (c) {
		case '{':
		case '[':
			token = new_token(tokens, capacity, &count,
			    c == '{' ? NVZA_JSON_OBJECT : NVZA_JSON_ARRAY,
			    (int)pos, parent);
			if (token < 0) return -1;
			parent = token;
			break;
		case '}':
		case ']':
			if (parent < 0 ||
			    (c == '}' && tokens[parent].type != NVZA_JSON_OBJECT) ||
			    (c == ']' && tokens[parent].type != NVZA_JSON_ARRAY)) {
				errno = EINVAL;
				return -1;
			}
			tokens[parent].end = (int)pos + 1;
			parent = tokens[parent].parent;
			break;
		case '"':
			token = new_token(tokens, capacity, &count, NVZA_JSON_STRING,
			    (int)pos + 1, parent);
			if (token < 0) return -1;
			for (pos++; pos < length; pos++) {
				c = json[pos];
				if (c == '"') break;
				if ((unsigned char)c < 0x20) {
					errno = EINVAL;
					return -1;
				}
				if (c == '\\') {
					if (++pos >= length || strchr("\"\\/bfnrtu", json[pos]) == NULL) {
						errno = EINVAL;
						return -1;
					}
					if (json[pos] == 'u') {
						if (pos + 4 >= length) { errno = EINVAL; return -1; }
						for (i = 1; i <= 4; i++)
							if (hex_value(json[pos + i]) < 0) { errno = EINVAL; return -1; }
						pos += 4;
					}
				}
			}
			if (pos >= length) { errno = EINVAL; return -1; }
			tokens[token].end = (int)pos;
			break;
		case ' ': case '\t': case '\r': case '\n': case ':': case ',':
			break;
		default:
			token = new_token(tokens, capacity, &count, NVZA_JSON_PRIMITIVE,
			    (int)pos, parent);
			if (token < 0) return -1;
			while (pos < length && strchr(" \t\r\n,]}", json[pos]) == NULL)
				pos++;
			tokens[token].end = (int)pos;
			pos--;
			break;
		}
	}
	if (parent != -1 || count == 0) {
		errno = EINVAL;
		return -1;
	}
	if ((size_t)count < capacity)
		tokens[count].start = INT_MAX;
	return count;
}

int
nvza_json_token_equals(const char *json, const struct nvza_json_token *token,
    const char *value)
{
	size_t length = strlen(value);
	return token != NULL && token->type == NVZA_JSON_STRING &&
	    token->end - token->start == (int)length &&
	    memcmp(json + token->start, value, length) == 0;
}

int
nvza_json_object_get(const char *json, const struct nvza_json_token *tokens,
    int object, const char *key)
{
	int direct_child = 0, i;

	if (object < 0 || tokens[object].type != NVZA_JSON_OBJECT)
		return -1;
	for (i = object + 1; tokens[i].start < tokens[object].end; i++) {
		if (tokens[i].parent != object)
			continue;
		/* Direct object children alternate between a key and its value. */
		if ((direct_child++ & 1) == 0 &&
		    nvza_json_token_equals(json, &tokens[i], key)) {
			if (tokens[i + 1].parent != object)
				return -1;
			return i + 1;
		}
	}
	return -1;
}

int
nvza_json_array_get(const struct nvza_json_token *tokens, int array, int index)
{
	int i, found = 0;

	if (array < 0 || index < 0 || tokens[array].type != NVZA_JSON_ARRAY)
		return -1;
	for (i = array + 1; tokens[i].start < tokens[array].end; i++) {
		if (tokens[i].parent == array && found++ == index)
			return i;
	}
	return -1;
}

static int
append_utf8(char *out, size_t capacity, size_t *used, unsigned value)
{
	unsigned char bytes[4];
	size_t count, i;
	if (value <= 0x7f) { bytes[0] = value; count = 1; }
	else if (value <= 0x7ff) { bytes[0] = 0xc0 | (value >> 6); bytes[1] = 0x80 | (value & 0x3f); count = 2; }
	else { bytes[0] = 0xe0 | (value >> 12); bytes[1] = 0x80 | ((value >> 6) & 0x3f); bytes[2] = 0x80 | (value & 0x3f); count = 3; }
	if (*used + count >= capacity) return -1;
	for (i = 0; i < count; i++) out[(*used)++] = (char)bytes[i];
	return 0;
}

char *
nvza_json_string_dup(const char *json, const struct nvza_json_token *token)
{
	char *out;
	size_t capacity, used = 0;
	int i, value, j;
	char c;

	if (token == NULL || token->type != NVZA_JSON_STRING) { errno = EINVAL; return NULL; }
	capacity = (size_t)(token->end - token->start) + 1;
	out = malloc(capacity);
	if (out == NULL) return NULL;
	for (i = token->start; i < token->end; i++) {
		c = json[i];
		if (c != '\\') { out[used++] = c; continue; }
		c = json[++i];
		switch (c) {
		case '"': case '\\': case '/': out[used++] = c; break;
		case 'b': out[used++] = '\b'; break;
		case 'f': out[used++] = '\f'; break;
		case 'n': out[used++] = '\n'; break;
		case 'r': out[used++] = '\r'; break;
		case 't': out[used++] = '\t'; break;
		case 'u':
			value = 0;
			for (j = 0; j < 4; j++) value = (value << 4) | hex_value(json[++i]);
			if (value == 0 || (value >= 0xd800 && value <= 0xdfff)) {
				free(out); errno = EINVAL; return NULL;
			}
			if (append_utf8(out, capacity, &used, (unsigned)value) != 0) { free(out); errno = ENOSPC; return NULL; }
			break;
		default: free(out); errno = EINVAL; return NULL;
		}
	}
	out[used] = '\0';
	return out;
}

static int
parse_integer(const char *json, const struct nvza_json_token *token,
    int negative_ok, uint64_t *magnitude, int *negative)
{
	int i;
	uint64_t value = 0, digit;
	if (token == NULL || token->type != NVZA_JSON_PRIMITIVE || token->start >= token->end) return -1;
	i = token->start;
	*negative = 0;
	if (json[i] == '-') { if (!negative_ok || ++i == token->end) return -1; *negative = 1; }
	for (; i < token->end; i++) {
		if (json[i] < '0' || json[i] > '9') return -1;
		digit = (uint64_t)(json[i] - '0');
		if (value > (UINT64_MAX - digit) / 10) return -1;
		value = value * 10 + digit;
	}
	*magnitude = value;
	return 0;
}

int nvza_json_uint64(const char *json, const struct nvza_json_token *token, uint64_t *out)
{ uint64_t v; int n; if (parse_integer(json, token, 0, &v, &n) != 0) return -1; *out = v; return 0; }

int nvza_json_int64(const char *json, const struct nvza_json_token *token, int64_t *out)
{
	uint64_t v; int n;
	if (parse_integer(json, token, 1, &v, &n) != 0) return -1;
	if ((!n && v > INT64_MAX) || (n && v > (uint64_t)INT64_MAX + 1)) return -1;
	*out = n ? (v == (uint64_t)INT64_MAX + 1 ? INT64_MIN : -(int64_t)v) : (int64_t)v;
	return 0;
}

int
nvza_json_bool(const char *json, const struct nvza_json_token *token, int *out)
{
	int length;
	if (token == NULL || token->type != NVZA_JSON_PRIMITIVE) return -1;
	length = token->end - token->start;
	if (length == 4 && memcmp(json + token->start, "true", 4) == 0) { *out = 1; return 0; }
	if (length == 5 && memcmp(json + token->start, "false", 5) == 0) { *out = 0; return 0; }
	return -1;
}
