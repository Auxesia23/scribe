# scribe

A small key-value store written in Zig, built as a learning project.

The goal is to learn Zig properly: allocators and ownership, binary-safe
protocol parsing, error sets, and testing. It is Redis-inspired, but the point
is the process, not production readiness.

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

- In-memory `Store` with owned keys and values, optional per-key expiry
  (`Item { value, expires_at_ms }`), lazy expiration, and an injectable `Clock`
- `set`, `setWithOptions`, `get`, `getCopy`, `remove`, `contains`, `count`,
  `clear`, `expire`, `ttl`, `persist`
- Ownership edge cases: overwrite, remove, clear, out-of-memory paths
- RESP2 subset: `PING`, `SET` (with `EX`/`PX`/`EXAT`/`PXAT`), `GET`, `DEL`,
  `EXISTS`, `TTL`, `PTTL`, `EXPIRE`, `PEXPIRE`, `PERSIST`
- Inline commands (`PING\r\n`, `SET key value\r\n`) as an alternative to RESP
- Binary-safe values (values may contain `\r\n`, NUL bytes, etc.)
- Explicit protocol limits (argument count, bulk size, line length, total command
  size)
- TCP server: single-connection accept loop, per-connection buffers, pipelined
  commands
- Engine/RESP split: `engine.zig` for command semantics, `resp.zig` for the RESP2
  codec, and `server.zig` wired to both
- 182 unit tests

Intentional deviations from Redis 8:

- Repeated SET options (`SET k v EX 5 EX 6`) are rejected with a syntax error;
  Redis accepts them and keeps the last value.
- `NX`/`XX`/`GET`/`KEEPTTL` on `SET` are not supported yet (syntax error); they
  are planned for a later phase.
- `EXPIRE NX/XX/GT/LT` flags and `EXPIREAT`/`PEXPIREAT` are not implemented.

Not implemented yet:

- Redis client compatibility (`HELLO`, `CLIENT`, `INFO`, `SELECT`, `AUTH`)
- Eviction / memory limits
- Multi-connection support; the server intentionally handles one connection at
  a time for now

Not planned for now:

- Persistence (AOF or snapshots). The store is in-memory only, so restarting the
  process loses all data.
- Multi-protocol support
- Cluster, replication, pub/sub, scripts, multi-db

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
redis-cli -p 6379 set k v ex 5  # OK, expires after 5 seconds
redis-cli -p 6379 ttl k         # remaining seconds (-2 if missing, -1 without expiry)
```

Without `redis-cli`, inline commands work over any TCP client:

```sh
printf 'PING\r\n' | nc -q 1 127.0.0.1 6379
```

Only one connection is served at a time for now; a second client waits until
the first one disconnects. This is intentional: the server is single-threaded,
and a many-connection event loop is planned after the functional features.

## Layout

```
build.zig
src/
  main.zig           entry point: store + server
  server.zig         TCP listener, single-connection accept loop
  server_test.zig    TCP tests (loopback)
  store.zig          in-memory key-value store with per-key expiry
  store_test.zig     store tests
  engine.zig         command semantics, independent of wire bytes
  engine_test.zig    engine tests
  resp.zig           RESP2 codec: readCommand / writeReply
  resp_test.zig      RESP2 codec tests
  tests.zig          test root that imports all test files
```

Planned: `event_loop.zig` for the multi-connection epoll loop.

## Design notes

### Ownership

- `Store.set` copies the key and value; caller buffers remain valid.
- `Store.get` returns a **borrowed** slice. It is only valid until that key is
  overwritten/removed, or the store is cleared/deinitialized.
- `Store.getCopy` returns caller-owned memory that must be freed by the caller.
- Protocol arguments are copied into a per-command arena and freed by resetting
  that arena after the reply is encoded, so nothing points into the reader's
  buffer.

### Expiry

- Every entry is `Item { value, expires_at_ms: ?i64 }`. The deadline is
  absolute epoch milliseconds; `null` means the key never expires.
- Expiration is **lazy**: any access compares the deadline against the store's
  clock and frees the entry in place when it has passed, so expired keys are
  indistinguishable from missing ones. `count` sweeps all entries for now; an
  active timer sweep is planned with the event loop.
- Time comes from an injected `Clock` (default: `clock_gettime`, REALTIME).
  Each store operation reads it at most once, so a single command observes a
  single consistent time. Tests inject a fake clock and never sleep.
- The engine resolves relative expiries (`EX`/`PX`/`EXPIRE`/`PEXPIRE`) against
  the store's clock. `SET` rejects non-positive expiry values; `EXPIRE`
  accepts zero/negative, which deletes the key and replies `1` — matching
  Redis.
- `TTL` replies `-2` for a missing key, `-1` for a key without expiry, and
  seconds rounded to the nearest second (`(ms + 500) / 1000`); `PTTL` reports
  raw milliseconds.

### Protocol

`resp.readCommand` parses exactly one command into an `engine.Command` backed by
a caller-provided arena. `engine.execute` runs the command against the `Store`
and returns a `Reply`. `resp.writeReply` encodes that reply as RESP2 bytes, and
the server resets the arena after flushing. The transport only supplies a reader
and a writer, so the codec and engine can be tested entirely in memory.

The error contract distinguishes:

- `EndOfStream` — the peer closed the connection between commands
- `Truncated` — EOF in the middle of a command frame
- `BadProtocol` — malformed input or a limit violation; the caller must close
  the connection because framing can no longer be trusted

Command-level failures (unknown command, wrong arity, bad `SET` options,
non-integer expiry values) are replied to as RESP errors and do **not** tear
down the connection.

Limits:

- `max_args = 128`
- `max_bulk_len = 1 MiB`
- `max_line_len = 4096`
- `max_command_len = 8 MiB` (total declared argument payload)

### Server

`Server.serve` accepts one connection at a time, then calls `resp.readCommand`,
`engine.execute`, and `resp.writeReply` in a loop, flushing after every command.
Pipelined commands are consumed from the same buffer without extra syscalls.

- The read buffer must be larger than `max_line_len` (8 KiB is used). Otherwise
  the delimiter may not fit in the reader buffer and legal input is rejected as
  `BadProtocol`.
- Codec and framing errors close only the current connection; listener errors
  abort `serve`.
- `stop` shuts the listening socket down, which is what wakes a blocked
  `accept`. Closing the socket would not.
- Bulk values larger than the buffer are streamed into the scratch allocator by
  `readSliceAll`, so the buffer size does not limit value size.

### Concurrency model

The server runtime is single-threaded. Today it accepts one connection at a time
and uses blocking I/O. The planned final model is one event-loop thread using
Linux `epoll` (level-triggered) with nonblocking sockets, per-connection
input/output buffers, and all commands executed serially. `poll` is the fallback
if portability becomes a requirement. That means:

- no thread-per-connection and no worker threads
- no `Mutex`/`RwLock` on the command path
- many connections can be open, but one slow command still blocks the loop

Tests may spawn threads to run the server and to implement watchdogs; the server
itself does not.

### Persistence

The store is in-memory only. Restarting the process loses all data. Persistence
(AOF or snapshots) is not part of the current roadmap; if it is added later, it
will be built on top of the event loop and the stable store format.

### Testing

- Protocol tests run entirely in memory with `std.Io.Reader.fixed` and
  `std.Io.Writer.Allocating`; no sockets are opened.
- Every test uses `std.testing.allocator`, so leaks and double frees fail the
  suite automatically.
- Expiry tests inject a deterministic fake clock into the store, so time
  travel (`now = 9_000`) is just an assignment and no test waits on real time.
- Out-of-memory paths are exercised with `std.testing.FailingAllocator`.
- Argument ownership is tested with `std.testing.Reader` and a one-byte
  artificial read limit, which forces the reader buffer to refill and rebase.
- TCP tests open real loopback sockets on an ephemeral port. A watchdog thread
  shuts the client down if the server stops responding, so a broken server
  fails instead of hanging the suite. Threads are only used as test harness;
  the server itself stays single-threaded.

## Roadmap

Done: TCP server, engine/RESP split, single-connection pipeline, TTL with
lazy expiration.

Next:

1. Redis client compatibility: `HELLO`, `CLIENT`, `INFO`, `SELECT`, `AUTH`
2. Eviction: `maxmemory` and an LRU policy
3. Multi-connection: a single-threaded `epoll` event loop, plus CLI flags
   (`--bind`, `--port`, `--maxclients`, ...)
4. Polish: `MGET`/`MSET`, `SCAN`/`KEYS`, `SET NX/XX`, logging, fuzzing,
   benchmarks

Not planned for now: persistence (AOF/snapshot), multi-protocol support,
cluster, replication, pub/sub, scripts, multi-db.

Feedback and corrections are welcome. This is a learning project, so rough
edges are expected.
