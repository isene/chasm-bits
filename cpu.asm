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
prefix:       db "C: "
prefix_len    equ $ - prefix

; Sensor names (newline-terminated to match what /sys writes). Walk in
; order; first match wins. INT3400 / acpitz / TZ00 are Dell-style
; control sensors that report a steady 20°C, so they're explicitly
; excluded — falling back to zone0 would hit them.
sensor_x86:    db "x86_pkg_temp", 10, 0
sensor_coret:  db "coretemp", 10, 0
sensor_tcpu:   db "TCPU", 10, 0

section .bss
buf1:    resb 256
buf2:    resb 256
load_buf: resb 64
temp_buf: resb 32
out_buf: resb 64
sleep_ts: resq 2

; Built per-invocation by find_cpu_zone: e.g. "/sys/class/thermal/thermal_zone11/temp\0"
zone_path: resb 64
zone_type_path: resb 64
zone_type_buf:  resb 64

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

    ; Find the CPU thermal zone (skip control sensors that report
    ; constant 20°C). Builds zone_path = "/sys/class/thermal/thermal_zoneN/temp"
    ; with N pointing at the matched zone, or fails the read otherwise.
    call find_cpu_zone
    test rax, rax
    js .no_temp
    lea rdi, [zone_path]
    lea rsi, [temp_buf]
    mov rdx, 32
    call read_file
    test rax, rax
    jle .no_temp
    ; Parse decimal millidegrees → integer degrees (round).
    xor r13d, r13d
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
    mov ecx, 2
    call itoa_pad
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
    mov ecx, 2
    call itoa_pad
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

; Walk /sys/class/thermal/thermal_zone[0..15]/type, looking for the
; CPU package sensor (x86_pkg_temp / coretemp / TCPU in that order).
; On hit, builds zone_path = "/sys/class/thermal/thermal_zoneN/temp"
; and returns 0 in rax. On miss returns -1 (caller skips the °).
;
; Why we don't fall back to zone0: on Dell laptops zone0 is INT3400
; or acpitz, a control sensor that reports a constant ~20°C — that's
; the bug we're fixing.
find_cpu_zone:
    push rbx
    push r12
    push r13
    xor r12d, r12d                          ; zone iterator
.fcz_loop:
    cmp r12, 16
    jge .fcz_miss
    ; Build "/sys/class/thermal/thermal_zoneN/type"
    lea rdi, [zone_type_path]
    call build_type_path
    ; Read the type file.
    lea rdi, [zone_type_path]
    lea rsi, [zone_type_buf]
    mov rdx, 64
    call read_file
    test rax, rax
    jle .fcz_next
    mov byte [zone_type_buf + rax], 0     ; ensure NUL-terminated
    ; Compare against each candidate sensor name.
    lea rdi, [zone_type_buf]
    lea rsi, [sensor_x86]
    call str_eq
    test eax, eax
    jnz .fcz_match
    lea rdi, [zone_type_buf]
    lea rsi, [sensor_coret]
    call str_eq
    test eax, eax
    jnz .fcz_match
    lea rdi, [zone_type_buf]
    lea rsi, [sensor_tcpu]
    call str_eq
    test eax, eax
    jnz .fcz_match
.fcz_next:
    inc r12
    jmp .fcz_loop
.fcz_match:
    ; Build "/sys/class/thermal/thermal_zoneN/temp" into zone_path.
    lea rdi, [zone_path]
    call build_temp_path
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret
.fcz_miss:
    mov rax, -1
    pop r13
    pop r12
    pop rbx
    ret

; rdi = dest buffer (≥ 64 bytes). r12 = zone index. Writes
; "/sys/class/thermal/thermal_zoneN/type\0".
build_type_path:
    push rbx
    mov rbx, rdi
    lea rsi, [.btp_pre]
    mov rcx, .btp_pre_len
    call copy_n_local
    mov rax, r12
    call itoa_local                       ; advances rdi
    lea rsi, [.btp_suf]
    mov rcx, .btp_suf_len
    call copy_n_local
    mov byte [rdi], 0
    mov rdi, rbx                          ; restore caller's dest pointer
    pop rbx
    ret
.btp_pre: db "/sys/class/thermal/thermal_zone"
.btp_pre_len equ $ - .btp_pre
.btp_suf: db "/type"
.btp_suf_len equ $ - .btp_suf

; rdi = dest. r12 = zone index. Writes ".../thermal_zoneN/temp\0".
build_temp_path:
    push rbx
    mov rbx, rdi
    lea rsi, [.btp2_pre]
    mov rcx, .btp2_pre_len
    call copy_n_local
    mov rax, r12
    call itoa_local
    lea rsi, [.btp2_suf]
    mov rcx, .btp2_suf_len
    call copy_n_local
    mov byte [rdi], 0
    mov rdi, rbx
    pop rbx
    ret
.btp2_pre: db "/sys/class/thermal/thermal_zone"
.btp2_pre_len equ $ - .btp2_pre
.btp2_suf: db "/temp"
.btp2_suf_len equ $ - .btp2_suf

; rdi = dest, rsi = src, rcx = count. Copies and ADVANCES rdi.
; Local copy because copy_n at the bottom doesn't preserve rsi the way
; we need here (and we want a smaller blast radius than touching it).
copy_n_local:
.cnl_loop:
    test rcx, rcx
    jz .cnl_done
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jmp .cnl_loop
.cnl_done:
    ret

; rax = number (≥ 0, fits in 8 digits), rdi = dest. Writes decimal
; digits and ADVANCES rdi past them. Builds digits backwards into a
; 16-byte stack scratch, then copies forward.
itoa_local:
    push rbx
    push r12
    push r13
    sub rsp, 16
    lea r13, [rsp + 16]                   ; one past end of digit buffer
    mov rbx, 10
    test rax, rax
    jnz .il_loop
    dec r13
    mov byte [r13], '0'
    jmp .il_emit
.il_loop:
    xor edx, edx
    div rbx
    add dl, '0'
    dec r13
    mov [r13], dl
    test rax, rax
    jnz .il_loop
.il_emit:
    lea r12, [rsp + 16]
    sub r12, r13                          ; digit count
.il_cp:
    test r12, r12
    jz .il_done
    mov al, [r13]
    mov [rdi], al
    inc r13
    inc rdi
    dec r12
    jmp .il_cp
.il_done:
    add rsp, 16
    pop r13
    pop r12
    pop rbx
    ret

; rdi, rsi = NUL-terminated strings. Returns 1 in eax if equal, 0 otherwise.
str_eq:
.se_loop:
    mov al, [rdi]
    cmp al, [rsi]
    jne .se_no
    test al, al
    je .se_yes
    inc rdi
    inc rsi
    jmp .se_loop
.se_yes:
    mov eax, 1
    ret
.se_no:
    xor eax, eax
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
    xor ebx, ebx                          ; total
    xor r13d, r13d                          ; idle
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
    xor eax, eax
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
; rax = num, rdi = buf, ecx = min width. Writes leading spaces if
; needed then the decimal digits; advances rdi past the result.
itoa_pad:
    push rbx
    push r12
    push r13
    mov r12, rcx                          ; min width
    ; Compute digit count → r13.
    mov rax, rax                          ; (no-op, rax stays)
    mov rbx, rax                          ; preserve original
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
    ; fall through into itoa
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
