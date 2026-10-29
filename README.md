# otp-socket-accept-wedge

A bug in OTP's `socket` module. After a select wakeup finds nothing to
accept, `socket:accept/1,2` from that process fails at once instead of waiting,
until a call finds a connection already queued. Other processes accepting on
the socket aren't woken. It affects 25.3.2.3, 26.0.2 and every later release
(OTP-18635), on Unix.

The error is `{error, {invalid, select_sent}}` since OTP-19684 (27.3.4.2,
28.0.2), and `{error, select_sent}` in 26.0.2 and 26.2.5.21. In 25.3.2.3,
27.3.4.1 and 28.0.1, `accept` raises a `case_clause` instead; an uncaught
raise kills the caller, which does wake the next acceptor.

CI runs the repro on OTP releases and on four source builds:

- `base`: master at the parent of
  [erlang/otp#11537](https://github.com/erlang/otp/pull/11537)
- `pr`: #11537, which lets a process that isn't the current acceptor accept
  directly
- `fix`: `base` plus [fix.patch](fix.patch)
- `pr-fix`: #11537 plus fix.patch

Both commits are pinned in [build.sh](build.sh).

## Scenarios

`wedge:check/0` runs three scenarios, each on a new listening socket L, and
prints a verdict for each.

- `dup` (`wedge:run/0`): L's current acceptor is woken, but a second
  descriptor for the same socket takes the connection. `wedged` if L's retry
  doesn't select again.
- `single`: after the wakeup, another process accepts on L before the retry.
  Stock OTP queues it, and the retry takes the connection (`queued`). With
  #11537 the other process takes the connection directly: `direct` if the
  retry then selects again, `wedged` if it fails.
- `stranded`: after the `dup` wakeup, the woken process retries, cancels with
  the handle the retry returned (as `socket:accept/2` does on timeout), and
  stops accepting. Another process then accepts on L and a client connects.
  `missed` if that process times out.

## Results

| OTP | dup | single | stranded |
|---|---|---|---|
| 25.3.2.2, 26.0.1 | ok | queued | missed\* |
| 25.3.2.3, 26.0.2 to 29.1.2 | wedged | queued | missed |
| `base` | wedged | queued | missed |
| `pr` | wedged | wedged | missed |
| `fix` | ok | queued | ok |
| `pr-fix` | ok | direct | ok |

\* No wedge. The retry selects with its new handle, but the NIF keeps the
first one, so `cancel` rejects the new handle and the select stays with the
woken process. That's
[erlang/otp#7328](https://github.com/erlang/otp/issues/7328). OTP-18635 fixed
it and introduced the wedge.

[expected.txt](expected.txt) lists each version. CI fails if a result differs.

## The fix

On `EAGAIN` the current acceptor cancels its select. It selects again only if
the cancel returns `ok`. After a wakeup, the one-shot select has already
fired, so the cancel returns `select_sent` and nothing is armed. In that case,
[fix.patch](fix.patch) reuses the acceptor's env and selects again with the new
handle, as the recv and sendfile retries do.

## Run

```sh
erlc wedge.erl && erl -noshell -s wedge check -s init stop
```

To compare with expected.txt, in an official image (Docker or Podman) or a
source build:

```sh
./check.sh 29.1.2
./build.sh fix && ./check.sh fix otp-fix
```

## License

Apache-2.0, like OTP.
