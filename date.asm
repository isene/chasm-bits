; date - print HH:MM wall clock to stdout, then exit.
; Part of chasm-bits, the per-segment status program suite for `strip`.
; Pure x86_64 NASM, no libc, single static binary.
;
; Output format: "HH:MM\n"  (5 bytes + NL)
;
; Build: nasm -f elf64 date.asm -o date.o && ld date.o -o date

%define SYS_WRITE         1
%define SYS_EXIT          60
%define SYS_CLOCK_GETTIME 228
%define CLOCK_REALTIME    0
%define STDOUT            1

section .bss
ts:        resq 2          ; struct timespec { tv_sec, tv_nsec }
out_buf:   resb 6          ; "HH:MM\n"

section .text
global _start
_start:
    ; clock_gettime(CLOCK_REALTIME, &ts)
    mov rax, SYS_CLOCK_GETTIME
    mov rdi, CLOCK_REALTIME
    lea rsi, [ts]
    syscall

    ; Read /etc/timezone offset via /proc/sys/kernel/... actually that
    ; doesn't expose offset. Real fix is parsing TZ binary at
    ; /etc/localtime. For now, hardcode CEST (+2h = 7200s) — this
    ; will drift by 1h on the DST transition but works for daily use.
    ; TODO: parse /etc/localtime tzif format properly (phase 2b.2).
    mov rax, [ts]                 ; tv_sec
    add rax, 7200                 ; CEST offset
    mov rcx, 86400
    xor edx, edx
    div rcx                        ; rax = days since epoch, rdx = secs in day
    mov rax, rdx
    mov rcx, 3600
    xor edx, edx
    div rcx                        ; rax = hour (0..23), rdx = secs in hour
    mov r8, rax                    ; save hour
    mov rax, rdx
    mov rcx, 60
    xor edx, edx
    div rcx                        ; rax = minute (0..59)
    mov r9, rax                    ; save minute

    ; Format "HH:MM\n" into out_buf.
    mov rax, r8                    ; hour
    mov rcx, 10
    xor edx, edx
    div rcx
    add al, '0'
    mov [out_buf + 0], al
    add dl, '0'
    mov [out_buf + 1], dl
    mov byte [out_buf + 2], ':'
    mov rax, r9                    ; minute
    xor edx, edx
    div rcx
    add al, '0'
    mov [out_buf + 3], al
    add dl, '0'
    mov [out_buf + 4], dl
    mov byte [out_buf + 5], 10     ; LF

    mov rax, SYS_WRITE
    mov rdi, STDOUT
    lea rsi, [out_buf]
    mov rdx, 6
    syscall

    mov rax, SYS_EXIT
    xor edi, edi
    syscall
