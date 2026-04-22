# chasm-bits

Tiny per-segment programs for the [`strip`](https://github.com/isene/tile)
status bar. Part of the [CHasm](https://github.com/isene/chasm) suite.

Each program is a single x86_64 NASM source file, no libc, pure
syscalls. Each does ONE thing: read some piece of system state,
format it, write it to stdout, exit. Static binaries, ~5-10 KB each.

`strip` spawns these as children on a refresh interval and reads their
stdout. Output may include ANSI SGR escapes (`ESC[Nm`) for color;
strip parses them and switches GC foreground per text-run.

## Programs (initial set)

| Program | Source                                         | What it reports                |
|---------|------------------------------------------------|--------------------------------|
| date    | `/proc/uptime` + clock_gettime → HH:MM         | wall clock                     |
| battery | `/sys/class/power_supply/BAT*/capacity` + status | percentage + charging glyph |
| cpu     | `/proc/loadavg`                                | 1-minute load                  |
| mem     | `/proc/meminfo`                                | available memory %             |
| disk    | `statfs(2)` on `/`                             | free disk %                    |
| ip      | `/proc/net/route` + `/proc/net/fib_trie`       | primary IPv4                   |
| sep     | (no input)                                     | colored separator glyph        |

## Build

Each program builds standalone with the same recipe:

```
nasm -f elf64 date.asm -o date.o && ld date.o -o date
```

The top-level `Makefile` builds them all in one shot.

## Usage with strip

```
# ~/.striprc
segment date    ~/bin/date          1
segment sep     ~/bin/sep
segment battery ~/bin/battery       30
segment sep     ~/bin/sep
segment cpu     ~/bin/cpu           5
segment tray
```

`segment NAME COMMAND INTERVAL` refreshes every INTERVAL seconds.
`segment NAME COMMAND` runs once at startup (e.g. static separators).
`segment NAME` for built-ins (`tray`, `title`).

## Adding a new bit

1. Write `bits/<name>.asm` that prints to stdout and exits.
2. Add the build target to `Makefile`.
3. Document in this README.

The `strip` side is language-agnostic — bits programs can be Rust, Go,
Ruby, anything. The asm versions in this repo are the canonical
"this is how you'd do it in pure x86_64" reference.
