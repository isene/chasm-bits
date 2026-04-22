; moonphase - print "<illum>%<+/->" matching the user's moonphase.rb.
; `+` = waning from full (angle > 180°), `-` = waxing toward full.
;
; Algorithm (ported from moonphase.rb):
;   synodic = 29.530588861 days
;   ref_fm  = 2459212.943... (reference full moon Julian Date)
;   jd      = clock_gettime(REALTIME) / 86400 + 2440587.5 + TZ_OFFSET
;   angle   = (((jd - ref_fm) / synodic) - trunc(...)) * 360°
;   illum   = floor((1 + cos(angle * π / 180)) * 50)
;   sign    = angle > 180° ? '+' : '-'
;
; Build: nasm -f elf64 moonphase.asm -o moonphase.o && ld moonphase.o -o moonphase

%define SYS_WRITE         1
%define SYS_EXIT          60
%define SYS_CLOCK_GETTIME 228
%define CLOCK_REALTIME    0

%define TZ_OFFSET_S       7200          ; CEST; conky uses +1 but +2 since DST

section .data
c_synodic:     dq 29.530588861
c_ref_fm:      dq 2459212.943372389     ; 2459198.177777778 + 29.530588861/2
c_unix_jd:     dq 2440587.5             ; JD of 1970-01-01 00:00 UTC
c_86400:       dq 86400.0
c_360:         dq 360.0
c_180:         dq 180.0
c_50:          dq 50.0
c_pi:          dq 3.14159265358979323846
c_one:         dq 1.0

section .bss
ts:        resq 2
out_buf:   resb 16

section .text
global _start
_start:
    mov rax, SYS_CLOCK_GETTIME
    mov rdi, CLOCK_REALTIME
    lea rsi, [ts]
    syscall

    mov rax, [ts]
    add rax, TZ_OFFSET_S
    cvtsi2sd xmm0, rax                   ; xmm0 = total_secs as double
    divsd xmm0, [c_86400]                ; xmm0 = days since epoch (double)
    addsd xmm0, [c_unix_jd]              ; xmm0 = jd
    subsd xmm0, [c_ref_fm]               ; xmm0 = delta days from reference full moon
    divsd xmm0, [c_synodic]              ; xmm0 = x = delta/synodic (cycles)

    ; x - floor(x). Works with cvttsd2si for positive x (delta is
    ; positive — ref_fm is in the past).
    cvttsd2si rax, xmm0
    cvtsi2sd xmm1, rax
    subsd xmm0, xmm1                     ; xmm0 = frac, 0..1
    mulsd xmm0, [c_360]                  ; xmm0 = angle_deg, 0..360
    movsd xmm2, xmm0                     ; save angle_deg for sign check

    ; rad = angle_deg * π / 180
    mulsd xmm0, [c_pi]
    divsd xmm0, [c_180]

    ; cos(rad) via x87. Spill to stack.
    sub rsp, 8
    movsd [rsp], xmm0
    fld qword [rsp]
    fcos
    fstp qword [rsp]
    movsd xmm0, [rsp]
    add rsp, 8

    ; illum = int((1 + cos) * 50)
    addsd xmm0, [c_one]
    mulsd xmm0, [c_50]
    cvttsd2si rax, xmm0
    mov r12, rax                         ; illum percent

    ; sign: '+' if angle_deg > 180 else '-'
    ucomisd xmm2, [c_180]
    ja .sign_plus
    mov r13, '-'
    jmp .sign_done
.sign_plus:
    mov r13, '+'
.sign_done:

    ; Format "<illum>%<sign>\n".
    lea rdi, [out_buf]
    mov rax, r12
    call itoa
    mov byte [rdi], '%'
    inc rdi
    mov [rdi], r13b
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

    mov rax, SYS_EXIT
    xor edi, edi
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
