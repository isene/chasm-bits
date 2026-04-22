; pingok - print "✓" if argv[1] (default www.vg.no) is reachable via
; a single ping, else "✗". Matches conky's `${if ping -c 1 -W 1 host;
; then echo O; else echo X; fi;}` pattern, with proper glyphs.
;
; Build: nasm -f elf64 pingok.asm -o pingok.o && ld pingok.o -o pingok

%define SYS_CLOSE  3
%define SYS_DUP2   33
%define SYS_OPEN   2
%define SYS_FORK   57
%define SYS_EXECVE 59
%define SYS_EXIT   60
%define SYS_WAIT4  61
%define SYS_WRITE  1

%define O_RDWR     2

section .data
ping_path:    db "/usr/bin/ping", 0
ping_arg0:    db "ping", 0
ping_argc:    db "-c1", 0
ping_argw:    db "-W1", 0
default_host: db "www.vg.no", 0
devnull:      db "/dev/null", 0
ok_str:       db 0xE2, 0x9C, 0x93, 10    ; UTF-8 ✓ + LF
ok_len        equ $ - ok_str
fail_str:     db 0xE2, 0x9C, 0x97, 10    ; UTF-8 ✗ + LF
fail_len      equ $ - fail_str

section .text
global _start
_start:
    mov rdi, [rsp]
    cmp rdi, 2
    jl .use_default
    mov r12, [rsp + 16]
    jmp .have_host
.use_default:
    lea r12, [default_host]
.have_host:

    mov rax, SYS_FORK
    syscall
    test rax, rax
    js .write_fail
    jz .child

    ; Parent: wait4.
    mov r13, rax
    sub rsp, 16
    mov rax, SYS_WAIT4
    mov rdi, r13
    lea rsi, [rsp]
    xor edx, edx
    xor r10d, r10d
    syscall
    mov eax, [rsp]
    add rsp, 16
    ; status: low byte 0 means clean exit; we want exit code 0 = success.
    test al, al
    jnz .write_fail                       ; signaled or stopped
    shr eax, 8
    test al, al
    jnz .write_fail
    mov rax, SYS_WRITE
    mov rdi, 1
    lea rsi, [ok_str]
    mov rdx, ok_len
    syscall
    jmp .die

.write_fail:
    mov rax, SYS_WRITE
    mov rdi, 1
    lea rsi, [fail_str]
    mov rdx, fail_len
    syscall
.die:
    mov rax, SYS_EXIT
    xor edi, edi
    syscall

.child:
    ; Redirect stdout + stderr to /dev/null so ping output stays out of strip.
    mov rax, SYS_OPEN
    lea rdi, [devnull]
    mov esi, O_RDWR
    xor edx, edx
    syscall
    test rax, rax
    js .child_exec
    mov rbx, rax
    mov rax, SYS_DUP2
    mov rdi, rbx
    mov rsi, 1
    syscall
    mov rax, SYS_DUP2
    mov rdi, rbx
    mov rsi, 2
    syscall
    mov rax, SYS_CLOSE
    mov rdi, rbx
    syscall
.child_exec:
    sub rsp, 48
    lea rax, [ping_arg0]
    mov [rsp + 0], rax
    lea rax, [ping_argc]
    mov [rsp + 8], rax
    lea rax, [ping_argw]
    mov [rsp + 16], rax
    mov [rsp + 24], r12
    mov qword [rsp + 32], 0
    mov rax, SYS_EXECVE
    lea rdi, [ping_path]
    mov rsi, rsp
    xor edx, edx
    syscall
    mov rax, SYS_EXIT
    mov edi, 127
    syscall
