; sep - print a coloured vertical-bar separator and exit.
; Output: "\033[34m|\033[0m\n"  → "|" in blue (SGR 34), reset.
; strip's ANSI SGR decoder colours it accordingly.
;
; Build: nasm -f elf64 sep.asm -o sep.o && ld sep.o -o sep

%define SYS_WRITE 1
%define SYS_EXIT  60

section .data
out: db 27, "[34m|", 27, "[0m", 10
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
