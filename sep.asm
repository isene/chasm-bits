; sep - print a coloured vertical-bar separator and exit.
; Output: ESC[38;2;100;100;100m|ESC[0m\n  → "|" in mid-grey, reset.
; strip's SGR decoder switches GC fg per the embedded escape.
;
; Build: nasm -f elf64 sep.asm -o sep.o && ld sep.o -o sep

%define SYS_WRITE 1
%define SYS_EXIT  60

section .data
out: db 27, "[38;2;100;100;100m|", 27, "[0m", 10
out_len equ $ - out

section .text
global _start
_start:
    mov rax, SYS_WRITE
    mov rdi, 1
    lea rsi, [out]
    mov rdx, out_len
    syscall
    mov rax, SYS_EXIT
    xor edi, edi
    syscall
