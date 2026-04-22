; mem - print "M:NN% NN%" matching conky's mem segment.
; Reads /proc/meminfo, computes used = (MemTotal - MemAvailable) and
; swap_used = (SwapTotal - SwapFree). Both as percentages.
;
; Build: nasm -f elf64 mem.asm -o mem.o && ld mem.o -o mem

%define SYS_READ   0
%define SYS_WRITE  1
%define SYS_OPEN   2
%define SYS_CLOSE  3
%define SYS_EXIT   60

section .data
proc_meminfo: db "/proc/meminfo", 0
k_total:    db "MemTotal:", 0
k_avail:    db "MemAvailable:", 0
k_swtotal:  db "SwapTotal:", 0
k_swfree:   db "SwapFree:", 0

section .bss
buf:     resb 4096
out_buf: resb 32

section .text
global _start
_start:
    ; Read meminfo.
    mov rax, SYS_OPEN
    lea rdi, [proc_meminfo]
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js .die
    mov r12, rax
    mov rax, SYS_READ
    mov rdi, r12
    lea rsi, [buf]
    mov rdx, 4095
    syscall
    mov r13, rax                          ; bytes read
    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall
    test r13, r13
    jle .die
    mov byte [buf + r13], 0

    ; Find each key, parse its value (first decimal number after ':').
    lea rdi, [k_total]
    call find_value
    mov r8, rax                           ; mem_total
    lea rdi, [k_avail]
    call find_value
    mov r9, rax                           ; mem_avail
    lea rdi, [k_swtotal]
    call find_value
    mov r10, rax                          ; sw_total
    lea rdi, [k_swfree]
    call find_value
    mov r11, rax                          ; sw_free

    ; mem_pct = (total - avail) * 100 / total.
    test r8, r8
    jz .mem_zero
    mov rax, r8
    sub rax, r9
    imul rax, 100
    xor edx, edx
    div r8
    jmp .have_mem
.mem_zero:
    xor eax, eax
.have_mem:
    mov r12, rax                          ; mem_pct

    ; sw_pct = (sw_total - sw_free) * 100 / sw_total.
    test r10, r10
    jz .sw_zero
    mov rax, r10
    sub rax, r11
    imul rax, 100
    xor edx, edx
    div r10
    jmp .have_sw
.sw_zero:
    xor eax, eax
.have_sw:
    mov r13, rax                          ; sw_pct

    ; Format "M:NN% NN%\n".
    lea rdi, [out_buf]
    mov byte [rdi], 'M'
    mov byte [rdi+1], ':'
    add rdi, 2
    mov rax, r12
    mov ecx, 3
    call itoa_pad
    mov byte [rdi], '%'
    inc rdi
    mov byte [rdi], ' '
    inc rdi
    mov rax, r13
    mov ecx, 2
    call itoa_pad
    mov byte [rdi], '%'
    inc rdi
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

; rdi = NUL-terminated key (e.g. "MemTotal:"). Searches buf for the
; key at line-start; parses the first decimal number after it. Returns
; rax = value (kB), or 0 if key not found.
find_value:
    push rbx
    push r12
    push r13
    mov r12, rdi                          ; key ptr
    lea r13, [buf]
.fv_lscan:
    mov al, [r13]
    test al, al
    jz .fv_zero
    ; Compare key against current line start.
    mov rsi, r12
    mov rdi, r13
.fv_cmp:
    mov al, [rsi]
    test al, al
    jz .fv_match
    cmp al, [rdi]
    jne .fv_skip
    inc rsi
    inc rdi
    jmp .fv_cmp
.fv_match:
    ; rdi points past key. Skip whitespace and parse decimal.
.fv_skip_ws:
    mov al, [rdi]
    cmp al, ' '
    je .fv_inc_ws
    cmp al, 9
    je .fv_inc_ws
    jmp .fv_parse
.fv_inc_ws:
    inc rdi
    jmp .fv_skip_ws
.fv_parse:
    xor rax, rax
.fv_dig:
    movzx ecx, byte [rdi]
    cmp cl, '0'
    jb .fv_done
    cmp cl, '9'
    ja .fv_done
    sub ecx, '0'
    imul rax, rax, 10
    add rax, rcx
    inc rdi
    jmp .fv_dig
.fv_done:
    pop r13
    pop r12
    pop rbx
    ret
.fv_skip:
    ; Advance r13 to next line.
.fv_skip_to_lf:
    mov al, [r13]
    test al, al
    jz .fv_zero
    cmp al, 10
    je .fv_past_lf
    inc r13
    jmp .fv_skip_to_lf
.fv_past_lf:
    inc r13
    jmp .fv_lscan
.fv_zero:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

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
