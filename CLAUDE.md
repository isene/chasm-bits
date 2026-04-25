# chasm-bits

The "asmites" — tiny x86_64 assembly binaries that print one line of
status text and exit. Used as segment commands in `strip` (the status
bar bundled with [tile](https://github.com/isene/tile)). Each asmite
is a single static ELF, typically ~5 KB, with zero dependencies
beyond the kernel.

## Build

```bash
make            # builds every asmite via `nasm -f elf64 X.asm -o X.o && ld X.o -o X`
```

The Makefile auto-discovers `*.asm` in this directory. Add a new
asmite by dropping a `foo.asm` file in.

## What is an asmite?

A tiny program that:
1. Reads its data source (sysfs / /proc / file / fork+exec a script)
2. Formats one line of output (or empty string)
3. Writes it to stdout
4. Exits with status 0

`strip` forks the asmite, captures stdout via pipe, displays the
result in the bar segment. Refresh interval is per-segment, set in
`~/.striprc` (e.g. `segment cpu #aaaaaa /path/to/cpu 4` runs every 4s).

A truly trivial example (`date.asm`) writes the current date and
exits in roughly 30 lines. The most complex asmite (`mailbox.asm`)
walks a maildir and counts unread messages.

## Asmite skeleton

```nasm
%define SYS_WRITE     1
%define SYS_EXIT     60

section .data
greeting: db "hello", 10
greeting_len equ $ - greeting

section .text
global _start

_start:
    mov rax, SYS_WRITE
    mov edi, 1                       ; stdout
    lea rsi, [greeting]
    mov rdx, greeting_len
    syscall

    mov rax, SYS_EXIT
    xor edi, edi
    syscall
```

That's the entire pattern. Most asmites are this skeleton plus some
data acquisition (one syscall to read sysfs) plus integer-to-decimal
conversion.

## Arg conventions

- `--length N` (e.g. `wintitle --length 40`): pad output to N chars
  with trailing spaces so the segment width is fixed
- `--dot`        : emit a single character indicator (●/○) instead
  of a number
- `+N` in striprc (NOT an asmite arg): tells strip to leave N extra
  pixels of leading gap before this segment

Asmite arg parsing is hand-written; there's no getopt. The pattern is:
walk envp first (skip), then walk argv looking for known flag strings.

## Output protocol

- Print **one line** (newline-terminated) and exit. Multi-line output
  is allowed but only the first line is shown by strip.
- Empty output (zero bytes written) renders as a blank segment —
  useful for "no battery", "no mail", "ping failed" cases.
- ANSI colour escapes are **not** parsed by strip; colour is set per
  segment via `#RRGGBB` in striprc, not by the asmite.
- Exit code 0 always (strip ignores it; non-zero gets the same
  treatment).

## Known asmites (current set)

| Asmite       | Reads                                        |
|--------------|---------------------------------------------|
| `clock`      | `gettimeofday` syscall                      |
| `date`       | same, formatted as YYYY-MM-DD               |
| `cpu`        | `/proc/stat` deltas                          |
| `mem`        | `/proc/meminfo`                              |
| `disk`       | `statfs` syscall on a path argument          |
| `battery`    | `/sys/class/power_supply/BAT*/`              |
| `brightness` | `/sys/class/backlight/*/brightness`          |
| `ip`         | `getaddrinfo` via `/etc/resolv.conf` parse   |
| `moonphase`  | computed from the date                       |
| `ping`       | fork + exec /bin/ping, parse output          |
| `pingok`     | shorter form, just ✓/✗                       |
| `mailbox`    | walks a maildir                              |
| `mailfetch`  | counts new mail since last run               |
| `wintitle`   | `_NET_WM_NAME` of `_NET_ACTIVE_WINDOW`       |
| `uptime`     | `/proc/uptime`                               |
| `sep`        | prints a separator (`│`)                     |

## Performance / battery rule

These run on `strip`'s timer (e.g. once per second for `clock`). Each
unnecessary fork is a wakeup that costs battery. Rules:

- Prefer `read()` from sysfs/proc to `fork+exec` of `cat`/`grep`/`awk`.
- Cache anything immutable (a path, a uid lookup) in BSS — do it once
  at startup, reuse forever.
- Static segments (interval=0 in striprc) only run once. Use them
  for things that never change between refreshes.
- A 1-second refresh × forking 3 helpers per refresh = 86,400 forks
  per day for one segment. The "no shell-out" rule isn't aesthetic.

## Pitfalls

See the global x86_64-asm skill for the 15 NASM/x86_64 pitfalls that
apply to every CHasm asm project. Asmite-specific:

- **No raw mode, no signal handlers needed** — asmites run for ms,
  exit, no termios state to manage.
- **Don't link libc** — `ld foo.o -o foo` only. If you find yourself
  wanting `printf`, write `itoa` (it's ~20 lines).
- **Output buffer should be in `.bss`** — not `.text`. Writing to
  `.text` segfaults; this bites people who put a small `db ' ' * 32`
  buffer between functions thinking it's writable.
