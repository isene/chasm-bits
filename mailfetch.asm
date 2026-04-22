; mailfetch - print "•" if ~/.mail.lock exists (gmail_fetch script
; is currently running), else "·" (dim placeholder, fixed-width).
; Mirrors conky's `${if_existing .mail.lock}.${else} ${endif}`.
;
; Build: nasm -f elf64 mailfetch.asm -o mailfetch.o && ld mailfetch.o -o mailfetch

%define SYS_OPEN  2
%define SYS_CLOSE 3
%define SYS_WRITE 1
%define SYS_EXIT  60

section .data
lockpath: db "/home/geir/.mail.lock", 0
on_str:   db 0xE2, 0x80, 0xA2, 10        ; UTF-8 • (bullet) + LF
on_len    equ $ - on_str
off_str:  db 0xC2, 0xB7, 10              ; UTF-8 · (middle dot) + LF
off_len   equ $ - off_str

section .text
global _start
_start:
    mov rax, SYS_OPEN
    lea rdi, [lockpath]
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js .off
    mov rdi, rax
    mov rax, SYS_CLOSE
    syscall
    mov rax, SYS_WRITE
    mov rdi, 1
    lea rsi, [on_str]
    mov rdx, on_len
    syscall
    jmp .die
.off:
    mov rax, SYS_WRITE
    mov rdi, 1
    lea rsi, [off_str]
    mov rdx, off_len
    syscall
.die:
    mov rax, SYS_EXIT
    xor edi, edi
    syscall
