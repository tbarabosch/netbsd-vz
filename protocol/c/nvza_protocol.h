#ifndef NVZA_PROTOCOL_H
#define NVZA_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#define NVZA_VERSION 1u
#define NVZA_HEADER_SIZE 32u
#define NVZA_MAX_CONTROL_PAYLOAD (1024u * 1024u)
#define NVZA_MAX_STREAM_PAYLOAD (64u * 1024u)
#define NVZA_MAX_BUFFERED_BYTES (4u * 1024u * 1024u)

enum nvza_frame_type {
	NVZA_FRAME_HOST_HELLO = 1,
	NVZA_FRAME_GUEST_READY = 2,
	NVZA_FRAME_REQUEST = 3,
	NVZA_FRAME_RESPONSE = 4,
	NVZA_FRAME_EVENT = 5,
	NVZA_FRAME_STDIN = 6,
	NVZA_FRAME_STDOUT = 7,
	NVZA_FRAME_STDERR = 8,
	NVZA_FRAME_STREAM_EOF = 9,
	NVZA_FRAME_COPY_DATA = 10,
	NVZA_FRAME_ERROR = 11
};

enum nvza_codec_result {
	NVZA_CODEC_ERROR = -1,
	NVZA_CODEC_NEED_MORE = 0,
	NVZA_CODEC_FRAME = 1
};

struct nvza_header {
	uint16_t version;
	uint16_t type;
	uint32_t flags;
	uint64_t request_id;
	uint64_t process_id;
	uint32_t payload_length;
};

struct nvza_frame {
	struct nvza_header header;
	uint8_t *payload;
};

struct nvza_decoder {
	uint8_t *bytes;
	size_t length;
	size_t capacity;
};

int nvza_frame_type_is_control(uint16_t);
int nvza_header_encode(uint8_t[NVZA_HEADER_SIZE], const struct nvza_header *);
int nvza_header_decode(struct nvza_header *, const uint8_t[NVZA_HEADER_SIZE]);

void nvza_decoder_init(struct nvza_decoder *);
void nvza_decoder_destroy(struct nvza_decoder *);
int nvza_decoder_feed(struct nvza_decoder *, const void *, size_t);
int nvza_decoder_next(struct nvza_decoder *, struct nvza_frame *);
void nvza_frame_destroy(struct nvza_frame *);

#endif
