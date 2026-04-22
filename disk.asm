; disk - print "D:NN% NNNG" matching conky's disk segment.
; statfs(2) on argv[1] (or "/home" by default), computes used %
; and free space in human-readable units (G/M/T).
;
; Build: nasm -f elf64 disk.asm -o disk.o && ld disk.o -o disk

%define SYS_WRITE  1
%define SYS_STATFS 137
%define SYS_EXIT   60

section .data
default_path: db "/home", 0

section .bss
statfs_buf: resb 120
out_buf:    resb 32

section .text
global _start
_start:
    ; argv[1] if present, else /home.
    mov rdi, [rsp]
    cmp rdi, 2
    jl .use_default
    mov rdi, [rsp + 16]
    jmp .have_path
.use_default:
    lea rdi, [default_path]
.have_path:
    mov rax, SYS_STATFS
    lea rsi, [statfs_buf]
    syscall
    test rax, rax
    js .die

    mov r8, [statfs_buf + 8]              ; bsize
    mov r9, [statfs_buf + 16]             ; blocks
    mov r10, [statfs_buf + 32]            ; bavail (user-visible free)

    ; used_pct = (blocks - bavail) * 100 / blocks.
    test r9, r9
    jz .pct_zero
    mov rax, r9
    sub rax, r10
    imul rax, 100
    xor edx, edx
    div r9
    jmp .have_pct
.pct_zero:
    xor eax, eax
.have_pct:
    mov r12, rax                          ; pct

    ; free_bytes = bavail * bsize. Pick units: G = >=1<<30, M = >=1<<20.
    mov rax, r10
    mul r8                                ; rdx:rax = bavail * bsize
    mov r13, rax                          ; assume fits in 64 bits

    ; Format " D:<pct>% <free><unit>\n" (leading space for visual gap).
    lea rdi, [out_buf]
    mov byte [rdi], ' '
    mov byte [rdi+1], 'D'
    mov byte [rdi+2], ':'
    add rdi, 3
    mov rax, r12
    mov ecx, 3
    call itoa_pad
    mov byte [rdi], '%'
    inc rdi
    mov byte [rdi], ' '
    inc rdi

    ; Choose unit.
    mov rax, r13
    mov rcx, 1
    shl rcx, 40                           ; 1 TiB
    cmp rax, rcx
    jge .unit_T
    mov rcx, 1
    shl rcx, 30                           ; 1 GiB
    cmp rax, rcx
    jge .unit_G
    mov rcx, 1
    shl rcx, 20                           ; 1 MiB
    cmp rax, rcx
    jge .unit_M
    mov rcx, 1
    shl rcx, 10
    cmp rax, rcx
    jge .unit_K
    jmp .write_raw
.unit_T:
    mov rcx, 1
    shl rcx, 40
    xor edx, edx
    div rcx
    call itoa
    mov byte [rdi], 'T'
    inc rdi
    jmp .nl
.unit_G:
    mov rcx, 1
    shl rcx, 30
    xor edx, edx
    div rcx
    call itoa
    mov byte [rdi], 'G'
    inc rdi
    jmp .nl
.unit_M:
    mov rcx, 1
    shl rcx, 20
    xor edx, edx
    div rcx
    call itoa
    mov byte [rdi], 'M'
    inc rdi
    jmp .nl
.unit_K:
    mov rcx, 1
    shl rcx, 10
    xor edx, edx
    div rcx
    call itoa
    mov byte [rdi], 'K'
    inc rdi
    jmp .nl
.write_raw:
    call itoa
    mov byte [rdi], 'B'
    inc rdi
.nl:
    mov byte [rdi], 10
    inc rdi
    lea rdx, [out_buf]
    sub rdi, rdx
    mov rdx, rdi
    mov rax, SYS_WRITE
    mov rdi, 1
    lea rsi, [out_buf]
    syscall
.die:
    mov rax, SYS_EXIT
    xor edi, edi
    syscall

itoa_pad:
    push rbx
    push r12
    push r13
    mov r12, rcx
    mov rbx, rax
    mov r13, 1
    mov rax, rbx
    mov rcx, 10
.ip_count:
    cmp rax, 10
    jb .ip_pad
    xor edx, edx
    div rcx
    inc r13
    jmp .ip_count
.ip_pad:
    mov rcx, r12
    sub rcx, r13
    jle .ip_emit
.ip_pad_loop:
    test rcx, rcx
    jz .ip_emit
    mov byte [rdi], ' '
    inc rdi
    dec rcx
    jmp .ip_pad_loop
.ip_emit:
    mov rax, rbx
    pop r13
    pop r12
    pop rbx

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
