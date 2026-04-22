; brightness - print "☼NN%" backlight percent to stdout, exit.
; Reads /sys/class/backlight/intel_backlight/{brightness,max_brightness}.
;
; Build: nasm -f elf64 brightness.asm -o brightness.o && ld brightness.o -o brightness

%define SYS_READ   0
%define SYS_WRITE  1
%define SYS_OPEN   2
%define SYS_CLOSE  3
%define SYS_EXIT   60

section .data
path_cur: db "/sys/class/backlight/intel_backlight/brightness", 0
path_max: db "/sys/class/backlight/intel_backlight/max_brightness", 0
prefix:   db "B:"                       ; ASCII (strip's "fixed" font is ISO 8859 only)
prefix_len equ 2

section .bss
buf:     resb 32
out_buf: resb 16

section .text
global _start
_start:
    lea rdi, [path_cur]
    call read_int
    mov r12, rax                        ; current
    lea rdi, [path_max]
    call read_int
    mov r13, rax                        ; max
    test r13, r13
    jz .die

    mov rax, r12
    mov rcx, 100
    mul rcx
    xor edx, edx
    div r13                             ; eax = percent

    ; Format "B:N%\n" into out_buf (itoa advances rdi in place).
    lea rdi, [out_buf]
    mov byte [rdi], 'B'
    mov byte [rdi+1], ':'
    add rdi, 2
    mov ecx, 3
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

; rdi = NUL-terminated file path. Returns rax = parsed int (0 on error).
read_int:
    push r12
    mov rax, SYS_OPEN
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js .ri_zero
    mov r12, rax
    mov rax, SYS_READ
    mov rdi, r12
    lea rsi, [buf]
    mov rdx, 31
    syscall
    push rax
    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall
    pop rcx
    test rcx, rcx
    jle .ri_zero
    xor eax, eax
    xor edx, edx
.ri_loop:
    cmp edx, ecx
    jge .ri_done
    movzx r8, byte [buf + rdx]
    sub r8, '0'
    cmp r8, 9
    ja .ri_done
    imul eax, eax, 10
    add eax, r8d
    inc edx
    jmp .ri_loop
.ri_done:
    pop r12
    ret
.ri_zero:
    xor eax, eax
    pop r12
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

; rax = number, rdi = buffer. Returns rax = digit count.
itoa:
    push rbx
    push r12
    mov rbx, 10
    test rax, rax
    jnz .it_nz
    mov byte [rdi], '0'
    mov rax, 1
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
    mov rax, r12
    pop r12
    pop rbx
    ret
