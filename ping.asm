; ping - print average ping ms (rounded, right-padded to 4 chars).
; Replaces the user's pingavg.rb. Forks /usr/bin/ping -c3 -W1 <host>
; (default 8.8.8.8 if no argv[1]), captures stdout, parses the
; "rtt min/avg/max/mdev = X/Y/Z/W ms" line, prints rounded Y.
;
; Build: nasm -f elf64 ping.asm -o ping.o && ld ping.o -o ping

%define SYS_READ   0
%define SYS_WRITE  1
%define SYS_CLOSE  3
%define SYS_PIPE   22
%define SYS_DUP2   33
%define SYS_FORK   57
%define SYS_EXECVE 59
%define SYS_EXIT   60
%define SYS_WAIT4  61

section .data
ping_path: db "/usr/bin/ping", 0
ping_arg0: db "ping", 0
ping_argc: db "-c3", 0
ping_argw: db "-W1", 0
default_host: db "8.8.8.8", 0
miss_str:  db "   -", 10
miss_len   equ $ - miss_str
needle:    db "min/avg/max/mdev = "
needle_len equ $ - needle

section .bss
buf:     resb 4096
out_buf: resb 16

section .text
global _start
_start:
    ; Pick host = argv[1] or default.
    mov rdi, [rsp]
    cmp rdi, 2
    jl .use_default_host
    mov r15, [rsp + 16]
    jmp .have_host
.use_default_host:
    lea r15, [default_host]
.have_host:

    ; pipe()
    sub rsp, 16
    mov rax, SYS_PIPE
    mov rdi, rsp
    syscall
    test rax, rax
    js .miss
    mov ebx, [rsp + 0]                    ; read end
    mov r12d, [rsp + 4]                   ; write end
    add rsp, 16

    mov rax, SYS_FORK
    syscall
    test rax, rax
    js .miss_close_both
    jz .child

    ; Parent.
    mov r13, rax                          ; child pid
    mov rax, SYS_CLOSE
    mov edi, r12d
    syscall
    xor r14, r14
.read_loop:
    mov rax, SYS_READ
    mov edi, ebx
    lea rsi, [buf]
    add rsi, r14
    mov rdx, 4095
    sub rdx, r14
    cmp rdx, 0
    jle .eof
    syscall
    test rax, rax
    jle .eof
    add r14, rax
    jmp .read_loop
.eof:
    mov byte [buf + r14], 0
    mov rax, SYS_CLOSE
    mov edi, ebx
    syscall
    sub rsp, 16
    mov rax, SYS_WAIT4
    mov rdi, r13
    lea rsi, [rsp]
    xor edx, edx
    xor r10d, r10d
    syscall
    add rsp, 16

    ; Find needle in buf.
    test r14, r14
    jz .miss
    xor rcx, rcx
.find:
    cmp ecx, r14d
    jge .miss
    mov ecx, ecx
    ; Compare needle starting at buf+rcx.
    push rcx
    mov edx, needle_len
    lea rdi, [buf]
    add rdi, rcx
    lea rsi, [needle]
.cmp_loop:
    test edx, edx
    jz .found
    mov al, [rdi]
    cmp al, [rsi]
    jne .cmp_no
    inc rdi
    inc rsi
    dec edx
    jmp .cmp_loop
.cmp_no:
    pop rcx
    inc rcx
    jmp .find
.found:
    pop rcx
    ; rdi points just past needle. Skip first number + '/'.
    add rcx, needle_len
    lea rdi, [buf]
    add rdi, rcx
.skip_first:
    mov al, [rdi]
    test al, al
    jz .miss
    cmp al, '/'
    je .past_first
    inc rdi
    jmp .skip_first
.past_first:
    inc rdi
    ; Now parse decimal (integer part, then optional .frac for rounding).
    xor eax, eax                          ; integer part
.parse_int:
    mov dl, [rdi]
    cmp dl, '0'
    jb .int_done
    cmp dl, '9'
    ja .int_done
    sub dl, '0'
    imul eax, eax, 10
    movzx edx, dl
    add eax, edx
    inc rdi
    jmp .parse_int
.int_done:
    cmp byte [rdi], '.'
    jne .have_avg
    inc rdi
    movzx edx, byte [rdi]
    sub dl, '0'
    cmp dl, 9
    ja .have_avg
    cmp dl, 5
    jb .have_avg
    inc eax                               ; round up
.have_avg:
    ; eax = rounded integer ms. Format right-padded to 4 chars + LF.
    mov r12d, eax                         ; preserve original value
    ; Count decimal digits.
    mov ecx, 1
    mov eax, r12d
    test eax, eax
    jz .ld_done
    xor ecx, ecx
.ld_loop:
    inc ecx
    xor edx, edx
    mov esi, 10
    div esi
    test eax, eax
    jnz .ld_loop
.ld_done:
    ; ecx = digit count. Pad to 4.
    lea rdi, [out_buf]
    mov edx, 4
    sub edx, ecx
    jle .write_digits
.pad_loop:
    test edx, edx
    jz .write_digits
    mov byte [rdi], ' '
    inc rdi
    dec edx
    jmp .pad_loop
.write_digits:
    mov eax, r12d
    call itoa
    mov byte [rdi], 10
    inc rdi
    lea rdx, [out_buf]
    sub rdi, rdx
    mov rdx, rdi
    mov rax, SYS_WRITE
    mov rdi, 1
    lea rsi, [out_buf]
    syscall
    jmp .die

.miss_close_both:
    mov rax, SYS_CLOSE
    mov edi, ebx
    syscall
    mov rax, SYS_CLOSE
    mov edi, r12d
    syscall
.miss:
    mov rax, SYS_WRITE
    mov rdi, 1
    lea rsi, [miss_str]
    mov rdx, miss_len
    syscall
.die:
    mov rax, SYS_EXIT
    xor edi, edi
    syscall

.child:
    mov rax, SYS_DUP2
    mov edi, r12d
    mov esi, 1
    syscall
    mov rax, SYS_CLOSE
    mov edi, ebx
    syscall
    cmp r12d, 1
    je .skip_close_w
    mov rax, SYS_CLOSE
    mov edi, r12d
    syscall
.skip_close_w:
    sub rsp, 48
    lea rax, [ping_arg0]
    mov [rsp + 0], rax
    lea rax, [ping_argc]
    mov [rsp + 8], rax
    lea rax, [ping_argw]
    mov [rsp + 16], rax
    mov [rsp + 24], r15
    mov qword [rsp + 32], 0
    mov rax, SYS_EXECVE
    lea rdi, [ping_path]
    mov rsi, rsp
    xor edx, edx
    syscall
    mov rax, SYS_EXIT
    mov edi, 127
    syscall

itoa:
    push rbx
    push r12
    mov rbx, 10
    test rax, rax
    jnz .it_nz
    mov byte [rdi], '0'
    inc rdi
    pop r12
    pop rbx
    ret
.it_nz:
    xor ecx, ecx
.it_loop:
    xor edx, edx
    div rbx
    add dl, '0'
    push rdx
    inc ecx
    test rax, rax
    jnz .it_loop
    mov r12, rcx
.it_pop:
    pop rdx
    mov [rdi], dl
    inc rdi
    loop .it_pop
    pop r12
    pop rbx
    ret
