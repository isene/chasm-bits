; ════════════════════════════════════════════════════════════════════════
; mailbox-multi — read ~/.mail2 once and print colour-coded counts for
; multiple mailboxes in a single fork.
;
; Usage:
;   mailbox-multi [--dot] LETTERS
;
;   LETTERS = one-char-per-mailbox string, e.g. "GPD".  Each letter
;   should match a line "X:N" in ~/.mail2.
;
;   --dot prepends a "." (or " " when ~/.mail.lock is absent) to the
;   FIRST letter, so the user can see when gmail_fetch is currently
;   running. The single dot/space replaces the per-segment --dot the
;   old config used on three separate segments.
;
; Replaces the three `mailbox G --dot / mailbox P / mailbox D` calls
; striprc was making every 30s. Net effect: 3 forks/refresh → 1 fork,
; and 9 write() syscalls → 1 (the whole bar segment is built in a
; single output buffer and written in one go).
;
; Output is ASCII + 24-bit SGR escapes; strip parses the SGR. Each
; mailbox count is shown in dim grey when the count is 0, otherwise
; in the per-letter colour from the user's existing palette.
;
; Build: nasm -f elf64 mailbox-multi.asm -o mailbox-multi.o &&
;        ld mailbox-multi.o -o mailbox-multi
; ════════════════════════════════════════════════════════════════════════

%define SYS_READ   0
%define SYS_WRITE  1
%define SYS_OPEN   2
%define SYS_CLOSE  3
%define SYS_EXIT   60

section .data
mail_path: db "/home/geir/.mail2", 0
lock_path: db "/home/geir/.mail.lock", 0

; 24-bit RGB SGR escapes (matches the existing mailbox.asm palette).
sgr_G:    db 27, "[38;2;251;189;143m"
sgr_G_len equ $ - sgr_G
sgr_A:    db 27, "[38;2;143;167;251m"
sgr_A_len equ $ - sgr_A
sgr_P:    db 27, "[38;2;206;143;251m"
sgr_P_len equ $ - sgr_P
sgr_D:    db 27, "[38;2;81;193;183m"
sgr_D_len equ $ - sgr_D
sgr_dim:  db 27, "[38;2;153;153;153m"
sgr_dim_len equ $ - sgr_dim
sgr_reset: db 27, "[0m"
sgr_reset_len equ $ - sgr_reset

section .bss
mail_buf:  resb 256                ; ~/.mail2 contents
out_buf:   resb 512                ; assembled output
dot_state: resb 1                  ; 1 = lock present, 0 = not

section .text
global _start

_start:
    ; Argv: argc @ [rsp], argv[0] @ [rsp+8], argv[1..] @ [rsp+16]+...
    mov rax, [rsp]
    cmp rax, 2
    jl .die                                 ; need ≥1 argument

    mov rbx, 1                              ; argv index for first non-flag
    mov byte [dot_state], 0
    mov r10, 0                              ; r10 = 1 if --dot in use

    ; Optional --dot flag.
    mov rdi, [rsp + 8 + rbx*8]
    cmp byte [rdi+0], '-'
    jne .arg_letters
    cmp byte [rdi+1], '-'
    jne .arg_letters
    cmp byte [rdi+2], 'd'
    jne .arg_letters
    cmp byte [rdi+3], 'o'
    jne .arg_letters
    cmp byte [rdi+4], 't'
    jne .arg_letters
    cmp byte [rdi+5], 0
    jne .arg_letters
    mov r10, 1
    inc rbx
    cmp rbx, [rsp]
    jge .die                                 ; --dot but no LETTERS
    mov rdi, [rsp + 8 + rbx*8]

    ; Probe ~/.mail.lock for dot state. open(O_RDONLY); if it succeeds
    ; the fetcher is running. Close immediately.
    push rdi
    mov rax, SYS_OPEN
    lea rdi, [lock_path]
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js .no_lock
    mov rdi, rax
    mov rax, SYS_CLOSE
    syscall
    mov byte [dot_state], 1
.no_lock:
    pop rdi

.arg_letters:
    ; rdi → letters string. r12 = saved letters ptr.
    mov r12, rdi

    ; Read ~/.mail2 once into mail_buf.
    mov rax, SYS_OPEN
    lea rdi, [mail_path]
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js .die
    mov r13, rax                            ; fd
    mov rax, SYS_READ
    mov rdi, r13
    lea rsi, [mail_buf]
    mov rdx, 256
    syscall
    mov r14, rax                            ; r14 = bytes read in mail_buf
    mov rax, SYS_CLOSE
    mov rdi, r13
    syscall
    test r14, r14
    jle .die

    ; r15 = output write position.
    lea r15, [out_buf]

    ; Emit dot or space if --dot was given. Use the same byte either way
    ; so the segment width stays fixed.
    test r10, r10
    jz .letters_loop
    cmp byte [dot_state], 1
    je .emit_dot
    mov byte [r15], ' '
    inc r15
    jmp .letters_loop
.emit_dot:
    mov byte [r15], '.'
    inc r15

.letters_loop:
    ; rdi cycles through r12 (letters string).
    mov rdi, r12
.next_letter:
    movzx eax, byte [rdi]
    test al, al
    jz .finish
    mov bl, al                              ; bl = current letter

    ; Find a line in mail_buf starting with bl. ecx = scan cursor.
    xor ecx, ecx
.scan:
    cmp ecx, r14d
    jge .skip_letter                        ; not found → skip with no output
    cmp [mail_buf + rcx], bl
    je .scan_found
.skip_to_lf:
    cmp ecx, r14d
    jge .skip_letter
    cmp byte [mail_buf + rcx], 10
    je .past_lf
    inc ecx
    jmp .skip_to_lf
.past_lf:
    inc ecx
    jmp .scan

.scan_found:
    ; Parse value following "X:".
    mov edx, ecx
    inc edx                                  ; past letter
    cmp edx, r14d
    jge .skip_letter
    cmp byte [mail_buf + rdx], ':'
    jne .skip_letter
    inc edx
    xor r8d, r8d
.peek_val:
    cmp edx, r14d
    jge .have_val
    movzx r9, byte [mail_buf + rdx]
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
    ; r8d = parsed value. Pick SGR by letter / value.
    push rdi                                ; save letters cursor
    push r12                                 ; save letters base (caller-saved by syscalls below)
    push r14
    test r8d, r8d
    jz .clr_dim
    cmp bl, 'G'
    je .pick_G
    cmp bl, 'A'
    je .pick_A
    cmp bl, 'P'
    je .pick_P
    cmp bl, 'D'
    je .pick_D
.clr_dim:
    lea rsi, [sgr_dim]
    mov ebp, sgr_dim_len
    jmp .emit_sgr
.pick_G:
    lea rsi, [sgr_G]
    mov ebp, sgr_G_len
    jmp .emit_sgr
.pick_A:
    lea rsi, [sgr_A]
    mov ebp, sgr_A_len
    jmp .emit_sgr
.pick_P:
    lea rsi, [sgr_P]
    mov ebp, sgr_P_len
    jmp .emit_sgr
.pick_D:
    lea rsi, [sgr_D]
    mov ebp, sgr_D_len
.emit_sgr:
    ; Copy SGR escape into out_buf.
    mov ecx, ebp
.cp_sgr:
    test ecx, ecx
    jz .cp_sgr_done
    mov al, [rsi]
    mov [r15], al
    inc rsi
    inc r15
    dec ecx
    jmp .cp_sgr
.cp_sgr_done:
    ; Copy "X:" + decimal value into out_buf.
    mov [r15], bl
    inc r15
    mov byte [r15], ':'
    inc r15
    ; Emit r8d as decimal (variable width).
    mov eax, r8d
    cmp eax, 1000
    jb .lt1000
    mov ecx, 1000
    xor edx, edx
    div ecx
    add al, '0'
    mov [r15], al
    inc r15
    mov eax, edx
.lt1000:
    cmp eax, 100
    jb .lt100
    mov ecx, 100
    xor edx, edx
    div ecx
    add al, '0'
    mov [r15], al
    inc r15
    mov eax, edx
.lt100:
    cmp eax, 10
    jb .lt10
    mov ecx, 10
    xor edx, edx
    div ecx
    add al, '0'
    mov [r15], al
    inc r15
    mov eax, edx
.lt10:
    add al, '0'
    mov [r15], al
    inc r15

    pop r14
    pop r12
    pop rdi
    ; Add a separator space if more letters follow.
    inc rdi
    cmp byte [rdi], 0
    je .last_letter
    mov byte [r15], ' '
    inc r15
    jmp .next_letter
.last_letter:
    jmp .finish

.skip_letter:
    inc rdi
    jmp .next_letter

.finish:
    ; Trailing reset + newline.
    lea rsi, [sgr_reset]
    mov ecx, sgr_reset_len
.cp_reset:
    test ecx, ecx
    jz .cp_reset_done
    mov al, [rsi]
    mov [r15], al
    inc rsi
    inc r15
    dec ecx
    jmp .cp_reset
.cp_reset_done:
    mov byte [r15], 10
    inc r15

    ; Single write() of the full buffer.
    mov rax, SYS_WRITE
    mov edi, 1
    lea rsi, [out_buf]
    mov rdx, r15
    sub rdx, rsi
    syscall

.die:
    mov rax, SYS_EXIT
    xor edi, edi
    syscall
