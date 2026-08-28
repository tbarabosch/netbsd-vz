#include "../nvza_protocol.h"

#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void
test_header_vector(void)
{
	const uint8_t expected[NVZA_HEADER_SIZE] = {
		0x4e, 0x56, 0x5a, 0x41, 0x00, 0x01, 0x00, 0x01,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02
	};
	struct nvza_header header = {
		.version = NVZA_VERSION,
		.type = NVZA_FRAME_HOST_HELLO,
		.request_id = 1,
		.payload_length = 2
	};
	struct nvza_header decoded;
	uint8_t bytes[NVZA_HEADER_SIZE];

	assert(nvza_header_encode(bytes, &header) == 0);
	assert(memcmp(bytes, expected, sizeof(expected)) == 0);
	assert(nvza_header_decode(&decoded, bytes) == 0);
	assert(decoded.version == header.version);
	assert(decoded.type == header.type);
	assert(decoded.request_id == header.request_id);
	assert(decoded.payload_length == header.payload_length);
}

static void
test_fragmentation_and_coalescing(void)
{
	struct nvza_header one = {
		.version = NVZA_VERSION,
		.type = NVZA_FRAME_RESPONSE,
		.request_id = 7,
		.payload_length = 2
	};
	struct nvza_header two = {
		.version = NVZA_VERSION,
		.type = NVZA_FRAME_STDOUT,
		.process_id = 9,
		.payload_length = 4
	};
	uint8_t bytes[2 * NVZA_HEADER_SIZE + 6];
	struct nvza_decoder decoder;
	struct nvza_frame frame;
	size_t offset = 0;

	assert(nvza_header_encode(bytes + offset, &one) == 0);
	offset += NVZA_HEADER_SIZE;
	memcpy(bytes + offset, "{}", 2);
	offset += 2;
	assert(nvza_header_encode(bytes + offset, &two) == 0);
	offset += NVZA_HEADER_SIZE;
	memcpy(bytes + offset, "\0\1\2\3", 4);
	offset += 4;

	nvza_decoder_init(&decoder);
	assert(nvza_decoder_feed(&decoder, bytes, 31) == 0);
	assert(nvza_decoder_next(&decoder, &frame) == NVZA_CODEC_NEED_MORE);
	assert(nvza_decoder_feed(&decoder, bytes + 31, offset - 31) == 0);
	assert(nvza_decoder_next(&decoder, &frame) == NVZA_CODEC_FRAME);
	assert(frame.header.request_id == 7);
	assert(memcmp(frame.payload, "{}", 2) == 0);
	nvza_frame_destroy(&frame);
	assert(nvza_decoder_next(&decoder, &frame) == NVZA_CODEC_FRAME);
	assert(frame.header.process_id == 9);
	assert(frame.payload[0] == 0 && frame.payload[3] == 3);
	nvza_frame_destroy(&frame);
	assert(nvza_decoder_next(&decoder, &frame) == NVZA_CODEC_NEED_MORE);
	nvza_decoder_destroy(&decoder);
}

static void
test_limits(void)
{
	struct nvza_header header = {
		.version = NVZA_VERSION,
		.type = NVZA_FRAME_STDOUT,
		.payload_length = NVZA_MAX_STREAM_PAYLOAD + 1
	};
	struct nvza_decoder decoder;
	uint8_t bytes[NVZA_HEADER_SIZE] = { 0 };
	uint8_t *large;

	assert(nvza_header_encode(bytes, &header) == -1);
	assert(errno == EINVAL);
	nvza_decoder_init(&decoder);
	large = calloc(1, NVZA_MAX_BUFFERED_BYTES);
	assert(large != NULL);
	assert(nvza_decoder_feed(&decoder, large, NVZA_MAX_BUFFERED_BYTES) == 0);
	assert(nvza_decoder_feed(&decoder, bytes, 1) == -1);
	assert(errno == ENOBUFS);
	free(large);
	nvza_decoder_destroy(&decoder);
}

static void
test_malformed_headers(void)
{
	struct nvza_header header = {
		.version = NVZA_VERSION,
		.type = NVZA_FRAME_REQUEST,
		.request_id = UINT64_C(0x0102030405060708),
		.process_id = UINT64_C(0x1112131415161718),
		.payload_length = 17
	};
	struct nvza_header decoded;
	uint8_t bytes[NVZA_HEADER_SIZE];

	assert(nvza_header_encode(bytes, &header) == 0);
	assert(bytes[12] == 0x01 && bytes[19] == 0x08);
	assert(bytes[20] == 0x11 && bytes[27] == 0x18);

	bytes[0] = 'X';
	assert(nvza_header_decode(&decoded, bytes) == -1 && errno == EPROTO);
	bytes[0] = 'N';
	bytes[5] = 2;
	assert(nvza_header_decode(&decoded, bytes) == -1 && errno == EPROTO);
	bytes[5] = 1;
	bytes[6] = 0x7f;
	bytes[7] = 0xff;
	assert(nvza_header_decode(&decoded, bytes) == -1 && errno == EPROTO);
}

int
main(void)
{
	test_header_vector();
	test_fragmentation_and_coalescing();
	test_limits();
	test_malformed_headers();
	puts("protocol C tests passed");
	return 0;
}
