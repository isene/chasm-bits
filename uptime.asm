; uptime - print uptime in days (one decimal) to stdout, exit.
; Reads /proc/uptime, parses seconds, divides by 86400.
;
; Build: nasm -f elf64 uptime.asm -o uptime.o && ld uptime.o -o uptime

%define SYS_READ   0
%define SYS_WRITE  1
%define SYS_OPEN   2
%define SYS_CLOSE  3
%define SYS_EXIT   60

section .data
proc_uptime: db "/proc/uptime", 0

section .bss
read_buf:  resb 64
out_buf:   resb 16

section .text
global _start
_start:
    mov rax, SYS_OPEN
    lea rdi, [proc_uptime]
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js .die
    mov r12, rax
    mov rax, SYS_READ
    mov rdi, r12
    lea rsi, [read_buf]
    mov rdx, 63
    syscall
    mov r13, rax
    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall
    test r13, r13
    jle .die

    ; Parse leading integer seconds (everything before '.').
    xor eax, eax
    xor ecx, ecx
.parse_int:
    cmp ecx, r13d
    jge .parse_done
    mov dl, [read_buf + rcx]
    cmp dl, '.'
    je .parse_done
    cmp dl, ' '
    je .parse_done
    sub dl, '0'
    cmp dl, 9
    ja .parse_done
    imul eax, eax, 10
    movzx edx, dl
    add eax, edx
    inc ecx
    jmp .parse_int
.parse_done:
    ; eax = seconds. Days = secs / 86400, fractional in tenths = (secs % 86400)*10/86400.
    mov ebx, eax
    mov ecx, 86400
    xor edx, edx
    div ecx                            ; eax = days, edx = remainder seconds
    mov r14d, eax                      ; days
    mov eax, edx
    mov ecx, 10
    mul ecx                            ; eax = remainder * 10 (fits in 32 bits)
    mov ecx, 86400
    xor edx, edx
    div ecx                            ; eax = tenths digit (0..9)
    mov r15d, eax

    ; Format "<days>.<tenth>\n" into out_buf. itoa advances rdi
    ; in-place, so the next byte is written at the new rdi.
    lea rdi, [out_buf]
    mov rax, r14
    call itoa
    mov byte [rdi], '.'
    inc rdi
    add r15d, '0'
    mov [rdi], r15b
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
