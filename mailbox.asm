; mailbox - print a single mailbox count line from ~/.mail2 with
; per-mailbox SGR colour. Usage:  mailbox <letter>
; e.g. mailbox G  →  ANSI-coloured "G:N\n"
; If the value is 0 the colour switches to dim grey instead.
;
; ~/.mail2 is a flat text file (one mailbox per line) maintained by
; the user's gmail_fetch script; this program does NOT do any IMAP.
;
; Build: nasm -f elf64 mailbox.asm -o mailbox.o && ld mailbox.o -o mailbox

%define SYS_READ   0
%define SYS_WRITE  1
%define SYS_OPEN   2
%define SYS_CLOSE  3
%define SYS_EXIT   60

section .data
mail_path: db "/home/geir/.mail2", 0

sgr_G: db 27, "[33m"            ; yellow/orange (Gmail)
sgr_A: db 27, "[34m"            ; blue
sgr_P: db 27, "[35m"            ; magenta
sgr_D: db 27, "[36m"            ; cyan
sgr_dim: db 27, "[90m"          ; bright black (dim) for zero
sgr_reset: db 27, "[0m", 10     ; reset + newline

section .bss
buf:        resb 256

section .text
global _start
_start:
    ; argv[0] = [rsp+8] (after argc); the letter is argv[1] = [rsp+16].
    mov rdi, [rsp]
    cmp rdi, 2
    jl .die
    mov rdi, [rsp + 16]
    mov al, [rdi]
    test al, al
    jz .die
    mov bl, al                           ; rbx low byte = letter (callee-saved)

    ; Open + read ~/.mail2.
    mov rax, SYS_OPEN
    lea rdi, [mail_path]
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js .die
    mov r12, rax
    mov rax, SYS_READ
    mov rdi, r12
    lea rsi, [buf]
    mov rdx, 256
    syscall
    mov r13, rax                         ; bytes read
    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall
    test r13, r13
    jle .die

    ; Walk lines; find one starting with bl. r14 = line start index.
    xor r14d, r14d
.scan:
    cmp r14d, r13d
    jge .die
    cmp [buf + r14], bl
    je .found
.skip_to_lf:
    cmp r14d, r13d
    jge .die
    cmp byte [buf + r14], 10
    je .past_lf
    inc r14d
    jmp .skip_to_lf
.past_lf:
    inc r14d
    jmp .scan

.found:
    ; Find LF (or end). r15 = end index (exclusive).
    mov r15d, r14d
.find_end:
    cmp r15d, r13d
    jge .have_end
    cmp byte [buf + r15], 10
    je .have_end
    inc r15d
    jmp .find_end
.have_end:

    ; Parse value (digits after "X:").
    mov edx, r14d
    inc edx                              ; past letter
    cmp edx, r15d
    jge .die
    cmp byte [buf + rdx], ':'
    jne .die
    inc edx
    xor r8d, r8d
.peek_val:
    cmp edx, r15d
    jge .have_val
    movzx r9, byte [buf + rdx]
    cmp r9b, '0'
    jb .have_val
    cmp r9b, '9'
    ja .have_val
    sub r9b, '0'
    imul r8d, r8d, 10
    add r8d, r9d
    inc edx
    jmp .peek_val
.have_val:
    ; Pick colour: dim if value is 0, otherwise by letter.
    test r8d, r8d
    jz .colour_dim
    cmp bl, 'G'
    je .clr_G
    cmp bl, 'A'
    je .clr_A
    cmp bl, 'P'
    je .clr_P
    cmp bl, 'D'
    je .clr_D
.colour_dim:
    lea r12, [sgr_dim]
    jmp .colour_set
.clr_G:
    lea r12, [sgr_G]
    jmp .colour_set
.clr_A:
    lea r12, [sgr_A]
    jmp .colour_set
.clr_P:
    lea r12, [sgr_P]
    jmp .colour_set
.clr_D:
    lea r12, [sgr_D]
.colour_set:

    ; Write SGR colour escape (5 bytes).
    mov rax, SYS_WRITE
    mov rdi, 1
    mov rsi, r12
    mov rdx, 5
    syscall

    ; Write line content [buf + r14 .. buf + r15).
    mov edx, r15d
    sub edx, r14d                        ; length
    mov rax, SYS_WRITE
    mov rdi, 1
    lea rsi, [buf]
    add rsi, r14
    syscall

    ; Write reset + LF (5 bytes).
    mov rax, SYS_WRITE
    mov rdi, 1
    lea rsi, [sgr_reset]
    mov rdx, 5
    syscall

.die:
    mov rax, SYS_EXIT
    xor edi, edi
    syscall
