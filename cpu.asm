; cpu - print "C: NN% N.NN NN°" matching conky's CPU segment.
; Samples /proc/stat twice (200ms apart) for instantaneous %, parses
; /proc/loadavg for the 1-min average, reads thermal_zone0 for temp.
;
; Build: nasm -f elf64 cpu.asm -o cpu.o && ld cpu.o -o cpu

%define SYS_READ      0
%define SYS_WRITE     1
%define SYS_OPEN      2
%define SYS_CLOSE     3
%define SYS_NANOSLEEP 35
%define SYS_EXIT      60

section .data
proc_stat:    db "/proc/stat", 0
proc_load:    db "/proc/loadavg", 0
thermal_path: db "/sys/class/thermal/thermal_zone0/temp", 0
prefix:       db "C: "
prefix_len    equ $ - prefix

section .bss
buf1:    resb 256
buf2:    resb 256
load_buf: resb 64
temp_buf: resb 32
out_buf: resb 64
sleep_ts: resq 2

section .text
global _start
_start:
    ; First snapshot of /proc/stat → buf1.
    lea rdi, [proc_stat]
    lea rsi, [buf1]
    mov rdx, 256
    call read_file
    mov r12, rax                          ; bytes read

    ; nanosleep 200ms = 200_000_000 ns.
    mov qword [sleep_ts + 0], 0
    mov qword [sleep_ts + 8], 200000000
    mov rax, SYS_NANOSLEEP
    lea rdi, [sleep_ts]
    xor esi, esi
    syscall

    ; Second snapshot.
    lea rdi, [proc_stat]
    lea rsi, [buf2]
    mov rdx, 256
    call read_file
    mov r13, rax

    ; Both buffers start with "cpu  USER NICE SYSTEM IDLE IOWAIT IRQ SOFTIRQ ..."
    ; Parse the aggregate line (first line, starts with "cpu " — note the
    ; double space because cpu# is left-aligned). Sum jiffies for
    ; non-idle vs total to get usage%.
    lea rdi, [buf1]
    call parse_cpu_jiffies
    mov r14, rax                          ; total1
    mov r15, rdx                          ; idle1
    lea rdi, [buf2]
    call parse_cpu_jiffies
    sub rax, r14                          ; total delta
    sub rdx, r15                          ; idle delta
    mov rcx, rax                          ; total_d
    mov rbx, rdx                          ; idle_d
    test rcx, rcx
    jz .pct_zero
    ; pct = (total_d - idle_d) * 100 / total_d
    mov rax, rcx
    sub rax, rbx
    mov rdx, 0
    imul rax, 100
    div rcx
    jmp .have_pct
.pct_zero:
    xor eax, eax
.have_pct:
    mov r12, rax                          ; cpu pct

    ; Read /proc/loadavg → first whitespace-separated token.
    lea rdi, [proc_load]
    lea rsi, [load_buf]
    mov rdx, 64
    call read_file
    ; Find first space → NUL it; load_buf now holds e.g. "0.60".
    xor ecx, ecx
.la_find_sp:
    cmp ecx, eax
    jge .la_done
    cmp byte [load_buf + rcx], ' '
    je .la_terminate
    inc ecx
    jmp .la_find_sp
.la_terminate:
    mov byte [load_buf + rcx], 0
.la_done:

    ; Read thermal temp (millidegrees).
    lea rdi, [thermal_path]
    lea rsi, [temp_buf]
    mov rdx, 32
    call read_file
    test rax, rax
    jle .no_temp
    ; Parse decimal millidegrees → integer degrees (round).
    xor r13, r13
    xor ecx, ecx
.tp_loop:
    cmp ecx, eax
    jge .tp_done
    movzx edx, byte [temp_buf + rcx]
    cmp dl, '0'
    jb .tp_done
    cmp dl, '9'
    ja .tp_done
    sub dl, '0'
    imul r13, r13, 10
    movzx edx, dl
    add r13, rdx
    inc ecx
    jmp .tp_loop
.tp_done:
    add r13, 500                          ; rounding
    mov rax, r13
    mov rcx, 1000
    xor edx, edx
    div rcx
    mov r13, rax                          ; temp in degrees C
    jmp .have_temp
.no_temp:
    mov r13, -1
.have_temp:

    ; Format "C: <pct>% <load> <temp>°\n".
    lea rdi, [out_buf]
    lea rsi, [prefix]
    mov rcx, prefix_len
    call copy_n
    mov rax, r12
    call itoa
    mov byte [rdi], '%'
    inc rdi
    mov byte [rdi], ' '
    inc rdi
    lea rsi, [load_buf]
    call copy_str
    mov byte [rdi], ' '
    inc rdi
    cmp r13, 0
    jl .skip_temp
    mov rax, r13
    call itoa
    mov byte [rdi], 0xC2                  ; UTF-8 ° = 0xC2 0xB0
    mov byte [rdi+1], 0xB0
    add rdi, 2
.skip_temp:
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

; rdi = path, rsi = buffer, rdx = max bytes. Returns rax = bytes read.
read_file:
    push rbx
    push r12
    mov r12, rsi                          ; preserve buffer
    push rdx
    mov rax, SYS_OPEN
    xor esi, esi
    xor edx, edx
    syscall
    pop rdx
    test rax, rax
    js .rf_zero
    mov rbx, rax
    mov rax, SYS_READ
    mov rdi, rbx
    mov rsi, r12
    syscall
    push rax
    mov rax, SYS_CLOSE
    mov rdi, rbx
    syscall
    pop rax
    pop r12
    pop rbx
    ret
.rf_zero:
    xor eax, eax
    pop r12
    pop rbx
    ret

; rdi = ptr to /proc/stat content. Parses the first "cpu " line.
; Returns rax = total jiffies (sum of all 7+ fields), rdx = idle jiffies (4th).
parse_cpu_jiffies:
    push rbx
    push r12
    push r13
    ; Skip "cpu  " (or "cpu " — variable spaces).
    mov r12, rdi
.pcj_skip_cpu:
    movzx eax, byte [r12]
    test al, al
    jz .pcj_zero
    cmp al, ' '
    je .pcj_skip_sp
    inc r12
    jmp .pcj_skip_cpu
.pcj_skip_sp:
    cmp byte [r12], ' '
    jne .pcj_first_field
    inc r12
    jmp .pcj_skip_sp
.pcj_first_field:
    xor rbx, rbx                          ; total
    xor r13, r13                          ; idle
    mov r8d, 0                            ; field index
.pcj_loop:
    cmp r8d, 7
    jge .pcj_done                         ; user, nice, system, idle, iowait, irq, softirq
    movzx eax, byte [r12]
    cmp al, 10
    je .pcj_done
    test al, al
    jz .pcj_done
    cmp al, ' '
    je .pcj_skip_field_sp
    cmp al, '0'
    jb .pcj_done
    cmp al, '9'
    ja .pcj_done
    ; Parse one decimal number.
    xor rax, rax
.pcj_dig:
    movzx ecx, byte [r12]
    cmp cl, '0'
    jb .pcj_dig_done
    cmp cl, '9'
    ja .pcj_dig_done
    sub ecx, '0'
    imul rax, rax, 10
    add rax, rcx
    inc r12
    jmp .pcj_dig
.pcj_dig_done:
    add rbx, rax                          ; total += value
    cmp r8d, 3
    jne .pcj_not_idle
    mov r13, rax                          ; field 3 (0-based) = idle
.pcj_not_idle:
    inc r8d
    jmp .pcj_loop
.pcj_skip_field_sp:
    inc r12
    jmp .pcj_loop
.pcj_done:
    mov rax, rbx
    mov rdx, r13
    pop r13
    pop r12
    pop rbx
    ret
.pcj_zero:
    xor eax, eax
    xor edx, edx
    pop r13
    pop r12
    pop rbx
    ret

; rdi = dest, rsi = src, rcx = count. Copies and advances rdi.
copy_n:
.cn_loop:
    test rcx, rcx
    jz .cn_done
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jmp .cn_loop
.cn_done:
    ret

; rdi = dest, rsi = src (NUL-terminated). Copies and advances rdi.
copy_str:
.cs_loop:
    mov al, [rsi]
    test al, al
    jz .cs_done
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .cs_loop
.cs_done:
    ret

; rax = number, rdi = buffer. Advances rdi past the digits.
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
