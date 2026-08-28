# NetBSD VZ Agent Protocol v1

The NetBSD VZ Agent protocol carries process control and byte streams between
the macOS runtime and the privileged guest agent. It is independent of the
underlying transport: version 1 uses a dedicated Virtio console device and a
future version may use Virtio-vsock without changing message semantics.

## Framing

Every frame starts with this 32-byte header. Multi-byte integers are unsigned
and encoded in network byte order.

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | ASCII magic `NVZA` |
| 4 | 2 | protocol version (`1`) |
| 6 | 2 | frame type |
| 8 | 4 | flags |
| 12 | 8 | request identifier |
| 20 | 8 | process identifier, or zero for VM-wide operations |
| 28 | 4 | payload length |

Control payloads are UTF-8 JSON and are limited to 1 MiB. Stream payloads are
opaque bytes and are limited to 64 KiB. A decoder may buffer at most 4 MiB.
The current serial transport sends at most 768 data bytes per frame and waits
for an acknowledgement because NetBSD tty input queues are smaller than the
wire-level maximum. Future vsock transports may use the full limit.

Frame types are stable once assigned:

1. `hostHello`
2. `guestReady`
3. `request`
4. `response`
5. `event`
6. `stdin`
7. `stdout`
8. `stderr`
9. `streamEOF`
10. `copyData`
11. `error`

Request identifiers correlate a response with a request. Process identifiers
are allocated by the host and remain valid until a successful `delete`
operation. Unsolicited output and exit events use request identifier zero.
Input and copy-data frames use a request identifier so the serial sender can
wait for `stdinAck`, `copyProgress`, or `copyComplete` events and apply
per-stream backpressure.

## Handshake

After opening the transport, the host sends `hostHello` with version 1 and the
capabilities it can consume. The guest responds with `guestReady`, its version,
capabilities, and agent build string. No other frame is valid before the
handshake completes. An unsupported version is answered with `error`, after
which the guest closes the transport.

## Control operations

`request`, `response`, `event`, and `error` frames contain JSON objects. The
`operation` field selects one of:

- `create`, `start`, `wait`, `signal`, `resize`, `closeStdin`, and `delete`
- `copyIn`, `copyOut`, and the internal `copyList` metadata operation
- `ping` and `shutdown`

`create` carries an executable and exact argument vector, environment entries,
working directory, credentials, resource limits, and optional initial terminal
size. A shell is never inserted. Callers that need shell evaluation explicitly
execute `/bin/sh -c`.

For a non-terminal process, stdout and stderr are separate streams. A terminal
process merges all output into stdout and immediately receives stderr EOF.
After process termination the guest drains output, emits EOF for every output
stream, and only then emits the final exit event and completes pending waits.

## File copy

Runtime APIs accept absolute guest paths, but wire path records are normalized
relative to `/`. Empty components, `.` and `..` components, embedded NULs, and
paths escaping the requested root are rejected. Entries are regular files,
directories, or symbolic links. `copyList` returns metadata for the requested
entry followed by its immediate children; the requested entry has an empty
relative `path`. The host recursively walks directories with bounded control
messages.

File bytes use ACK-paced `copyData` frames correlated by request identifier.
`copyComplete` acknowledges the final frame and `streamEOF` terminates copy-out
data. Implementations use directory file descriptors and `openat`-style
operations and never invoke a shell.

## Security and errors

The version 1 serial channel exists only between the VZ host process and the
root-owned `/dev/ttyVI10` guest device. It is intentionally not exposed over a
network. Both peers validate frame lengths before allocating memory. Protocol,
validation, unsupported-operation, and process errors use stable string codes
plus a human-readable message; malformed framing terminates the connection.
