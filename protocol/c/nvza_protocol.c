#include "nvza_protocol.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

static const uint8_t nvza_magic[4] = { 'N', 'V', 'Z', 'A' };

static uint16_t
load_be16(const uint8_t *p)
{
	return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static uint32_t
load_be32(const uint8_t *p)
{
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
	    ((uint32_t)p[2] << 8) | p[3];
}

static uint64_t
load_be64(const uint8_t *p)
{
	return ((uint64_t)load_be32(p) << 32) | load_be32(p + 4);
}

static void
store_be16(uint8_t *p, uint16_t value)
{
	p[0] = (uint8_t)(value >> 8);
	p[1] = (uint8_t)value;
}

static void
store_be32(uint8_t *p, uint32_t value)
{
	p[0] = (uint8_t)(value >> 24);
	p[1] = (uint8_t)(value >> 16);
	p[2] = (uint8_t)(value >> 8);
	p[3] = (uint8_t)value;
}

static void
store_be64(uint8_t *p, uint64_t value)
{
	store_be32(p, (uint32_t)(value >> 32));
	store_be32(p + 4, (uint32_t)value);
}

int
nvza_frame_type_is_control(uint16_t type)
{
	return type == NVZA_FRAME_HOST_HELLO ||
	    type == NVZA_FRAME_GUEST_READY ||
	    type == NVZA_FRAME_REQUEST ||
	    type == NVZA_FRAME_RESPONSE ||
	    type == NVZA_FRAME_EVENT ||
	    type == NVZA_FRAME_ERROR;
}

int
nvza_header_encode(uint8_t out[NVZA_HEADER_SIZE], const struct nvza_header *h)
{
	uint32_t limit;

	if (h == NULL) {
		errno = EINVAL;
		return -1;
	}
	limit = nvza_frame_type_is_control(h->type) ?
	    NVZA_MAX_CONTROL_PAYLOAD : NVZA_MAX_STREAM_PAYLOAD;
	if (h->version != NVZA_VERSION || h->type < NVZA_FRAME_HOST_HELLO ||
	    h->type > NVZA_FRAME_ERROR || h->payload_length > limit) {
		errno = EINVAL;
		return -1;
	}
	memcpy(out, nvza_magic, sizeof(nvza_magic));
	store_be16(out + 4, h->version);
	store_be16(out + 6, h->type);
	store_be32(out + 8, h->flags);
	store_be64(out + 12, h->request_id);
	store_be64(out + 20, h->process_id);
	store_be32(out + 28, h->payload_length);
	return 0;
}

int
nvza_header_decode(struct nvza_header *h, const uint8_t in[NVZA_HEADER_SIZE])
{
	uint32_t limit;

	if (h == NULL || in == NULL) {
		errno = EINVAL;
		return -1;
	}
	if (memcmp(in, nvza_magic, sizeof(nvza_magic)) != 0) {
		errno = EPROTO;
		return -1;
	}
	h->version = load_be16(in + 4);
	h->type = load_be16(in + 6);
	h->flags = load_be32(in + 8);
	h->request_id = load_be64(in + 12);
	h->process_id = load_be64(in + 20);
	h->payload_length = load_be32(in + 28);
	if (h->version != NVZA_VERSION || h->type < NVZA_FRAME_HOST_HELLO ||
	    h->type > NVZA_FRAME_ERROR) {
		errno = EPROTO;
		return -1;
	}
	limit = nvza_frame_type_is_control(h->type) ?
	    NVZA_MAX_CONTROL_PAYLOAD : NVZA_MAX_STREAM_PAYLOAD;
	if (h->payload_length > limit) {
		errno = EMSGSIZE;
		return -1;
	}
	return 0;
}

void
nvza_decoder_init(struct nvza_decoder *decoder)
{
	memset(decoder, 0, sizeof(*decoder));
}

void
nvza_decoder_destroy(struct nvza_decoder *decoder)
{
	if (decoder == NULL)
		return;
	free(decoder->bytes);
	memset(decoder, 0, sizeof(*decoder));
}

int
nvza_decoder_feed(struct nvza_decoder *decoder, const void *bytes, size_t length)
{
	size_t needed, capacity;
	uint8_t *replacement;

	if (decoder == NULL || (bytes == NULL && length != 0)) {
		errno = EINVAL;
		return -1;
	}
	if (length > NVZA_MAX_BUFFERED_BYTES - decoder->length) {
		errno = ENOBUFS;
		return -1;
	}
	needed = decoder->length + length;
	if (needed > decoder->capacity) {
		capacity = decoder->capacity == 0 ? 4096 : decoder->capacity;
		while (capacity < needed) {
			if (capacity > NVZA_MAX_BUFFERED_BYTES / 2) {
				capacity = NVZA_MAX_BUFFERED_BYTES;
				break;
			}
			capacity *= 2;
		}
		replacement = realloc(decoder->bytes, capacity);
		if (replacement == NULL)
			return -1;
		decoder->bytes = replacement;
		decoder->capacity = capacity;
	}
	if (length != 0)
		memcpy(decoder->bytes + decoder->length, bytes, length);
	decoder->length = needed;
	return 0;
}

int
nvza_decoder_next(struct nvza_decoder *decoder, struct nvza_frame *frame)
{
	size_t frame_length, remaining;

	if (decoder == NULL || frame == NULL) {
		errno = EINVAL;
		return NVZA_CODEC_ERROR;
	}
	memset(frame, 0, sizeof(*frame));
	if (decoder->length < NVZA_HEADER_SIZE)
		return NVZA_CODEC_NEED_MORE;
	if (nvza_header_decode(&frame->header, decoder->bytes) != 0)
		return NVZA_CODEC_ERROR;
	frame_length = NVZA_HEADER_SIZE + frame->header.payload_length;
	if (decoder->length < frame_length)
		return NVZA_CODEC_NEED_MORE;
	if (frame->header.payload_length != 0) {
		frame->payload = malloc(frame->header.payload_length);
		if (frame->payload == NULL)
			return NVZA_CODEC_ERROR;
		memcpy(frame->payload, decoder->bytes + NVZA_HEADER_SIZE,
		    frame->header.payload_length);
	}
	remaining = decoder->length - frame_length;
	if (remaining != 0)
		memmove(decoder->bytes, decoder->bytes + frame_length, remaining);
	decoder->length = remaining;
	return NVZA_CODEC_FRAME;
}

void
nvza_frame_destroy(struct nvza_frame *frame)
{
	if (frame == NULL)
		return;
	free(frame->payload);
	memset(frame, 0, sizeof(*frame));
}
