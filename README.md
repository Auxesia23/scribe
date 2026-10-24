# scribe

A small key-value store written in Zig, built as a learning project.

The goal is to learn Zig properly: allocators and ownership, binary-safe
protocol parsing, error sets, and testing. It is Redis/memcached-inspired, but
the point is the process, not production readiness.

## How I'm learning

I'm using an LLM as a guide/tutor, and work test-driven:

1. I describe the next feature.
2. The model writes failing tests (the spec) and implementation notes.
3. I implement until `zig build test` is green.

So the tests in this repository were written before the implementations. I wrote
the implementations; the model wrote the tests, explanations, and reviews. The
code is intentionally small and explicit because it doubles as study material.

## Status

Implemented and tested:

- In-memory `Store` with owned keys and values
- `set`, `get`, `getCopy`, `remove`, `contains`, `count`, `clear`
- Ownership edge cases: overwrite, remove, clear, out-of-memory paths
- RESP2 subset: `PING`, `SET`, `GET`, `DEL`, `EXISTS`
- Inline commands (`PING\r\n`, `SET key value\r\n`) as an alternative to RESP
- Binary-safe values (values may contain `\r\n`, NUL bytes, etc.)
- Explicit protocol limits (argument count, bulk size, line length)
- TCP server: accept loop, per-connection buffers, pipelined commands
- 82 unit tests

Not implemented yet:

- Concurrency (the server handles one connection at a time)
- TTL / expiration
- Persistence
- Eviction / memory limits

## Requirements

- Zig master (`0.17.0`) with the new `std.Io` reader/writer interfaces
- No external dependencies

## Build and test

```sh
zig build        # build the executable
zig build test   # run all unit tests
zig build run    # start the server on 127.0.0.1:6379
```

The server blocks until the process is killed. In another terminal:

```sh
redis-cli -p 6379 ping          # PONG
redis-cli -p 6379 set name john # OK
redis-cli -p 6379 get name      # "john"
```

Without `redis-cli`, inline commands work over any TCP client:

```sh
printf 'PING\r\n' | nc -q 1 127.0.0.1 6379
```

Only one connection is served at a time for now; a second client waits until
the first one disconnects.

## Layout

```
build.zig
src/
  main.zig           entry point: store + server
  server.zig         TCP listener, accept loop, per-connection buffers
  server_test.zig    TCP tests (loopback)
  store.zig          in-memory key-value store
  store_test.zig     store tests
  protocol.zig       RESP2 + inline command parsing and dispatch
  protocol_test.zig  protocol tests
  tests.zig          test root that imports all test files
```

## Design notes

### Ownership

- `Store.set` copies the key and value; caller buffers remain valid.
- `Store.get` returns a **borrowed** slice. It is only valid until that key is
  overwritten/removed, or the store is cleared/deinitialized.
- `Store.getCopy` returns caller-owned memory that must be freed by the caller.
- Protocol arguments are copied into a per-command scratch allocator and freed
  after dispatch, so nothing points into the reader's buffer.

### Protocol

`protocol.execute` reads exactly one command from a reader, executes it, and
writes the reply to a writer. It does not know whether the underlying transport
is a socket or an in-memory buffer.

The error contract distinguishes:

- `EndOfStream` — the peer closed the connection between commands
- `Truncated` — EOF in the middle of a command frame
- `BadProtocol` — malformed input or a limit violation; the caller must close
  the connection because framing can no longer be trusted

Command-level failures (unknown command, wrong arity) are replied to as RESP
errors and do **not** tear down the connection.

Limits:

- `max_args = 128`
- `max_bulk_len = 1 MiB`
- `max_line_len = 4096`

### Server

`Server.serve` accepts one connection at a time, then runs
`protocol.execute` in a loop and flushes after every command. Pipelined
commands are consumed from the same buffer without extra syscalls.

- The read buffer must be larger than `max_line_len` (8 KiB is used). Otherwise
  `takeDelimiter` cannot see the delimiter and legal input is rejected as
  `BadProtocol`.
- Protocol and framing errors close only the current connection; listener
  errors abort `serve`.
- `stop` shuts the listening socket down, which is what wakes a blocked
  `accept`. Closing the socket would not.
- Bulk values larger than the buffer are streamed into the scratch allocator by
  `readSliceAll`, so the buffer size does not limit value size.

### Testing

- Protocol tests run entirely in memory with `std.Io.Reader.fixed` and
  `std.Io.Writer.Allocating`; no sockets are opened.
- Every test uses `std.testing.allocator`, so leaks and double frees fail the
  suite automatically.
- Out-of-memory paths are exercised with `std.testing.FailingAllocator`.
- Argument ownership is tested with `std.testing.Reader` and a one-byte
  artificial read limit, which forces the reader buffer to refill and rebase.
- TCP tests open real loopback sockets on an ephemeral port. A watchdog thread
  shuts the client down if the server stops responding, so a broken server
  fails instead of hanging the suite.

## Roadmap

Done: TCP server (accept loop, per-connection buffers, `execute`, `flush` per
command).

Next:

1. CLI flags (`--bind`, `--port`); the defaults are currently hardcoded
2. Concurrency: thread-per-connection with a mutex, or sharded stores
3. TTL: `SET ... EX`, `EXPIRE`, `TTL`, lazy expiration
4. Persistence: append-only log and/or snapshots
5. Eviction: `maxmemory` and an LRU policy

Feedback and corrections are welcome. This is a learning project, so rough
edges are expected.
