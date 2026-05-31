; battery - print "<S> NN% N.Nh N.NNW[ G]" matching conky's battery line.
;   S = D (discharging) / C (charging) / F (full) / N (not charging)
;   NN% = capacity
;   N.Nh = hours of runtime left (only if discharging)
;   N.NNW = current power draw
;   G = optional wifi power_save glyph appended at end:
;       'V' (V-down ▼) when power_save is ON (battery-saver, iwlwifi
;       freeze risk). Absent when OFF (default stable mode) or unknown.
;       Source: /run/user/$UID/wifi-pwrsave, 1 byte ('1'=ON, '0'=OFF),
;       written by ~/bin/wifi-pwrsave-state and wifi-stability-toggle.
; Uses /sys/class/power_supply/BAT0/{capacity,status,power_now,energy_now}.
; Optional argv[1] = battery name (default "BAT0").
;
; Build: nasm -f elf64 battery.asm -o battery.o && ld battery.o -o battery

%define SYS_READ   0
%define SYS_WRITE  1
%define SYS_OPEN   2
%define SYS_CLOSE  3
%define SYS_EXIT   60
%define SYS_GETUID 102

section .data
sys_pre:    db "/sys/class/power_supply/", 0
sys_pre_len equ $ - sys_pre - 1
default_bat: db "BAT0", 0
suf_cap:    db "/capacity", 0
suf_stat:   db "/status", 0
suf_power:  db "/power_now", 0
suf_energy: db "/energy_now", 0
suf_volt:   db "/voltage_now", 0
suf_curr:   db "/current_now", 0
suf_charge: db "/charge_now", 0
run_user_pre:        db "/run/user/"
run_user_pre_len     equ $ - run_user_pre
wifi_pwrsave_suf:    db "/wifi-pwrsave", 0
wifi_pwrsave_suf_len equ $ - wifi_pwrsave_suf

section .bss
path_buf:   resb 256
read_buf:   resb 64
out_buf:    resb 64
wifi_path:  resb 64
wifi_state: resb 1

section .text
global _start
_start:
    ; Read wifi power-save state (1 byte from /run/user/<uid>/wifi-pwrsave).
    ; wifi_state stays 0 (BSS zero-init) on any failure: missing tmpfs,
    ; missing file, short read. Cost when file is absent: getuid + open
    ; (ENOENT) — ~2 syscalls, no extra wakeups.
    lea rdi, [wifi_path]
    lea rsi, [run_user_pre]
    mov ecx, run_user_pre_len
    rep movsb
    mov rax, SYS_GETUID
    syscall
    call itoa                             ; appends decimal uid, advances rdi
    lea rsi, [wifi_pwrsave_suf]
    mov ecx, wifi_pwrsave_suf_len
    rep movsb                             ; copies "/wifi-pwrsave" + NUL
    mov rax, SYS_OPEN
    lea rdi, [wifi_path]
    xor esi, esi                          ; O_RDONLY
    xor edx, edx
    syscall
    test rax, rax
    js .wifi_done
    mov rbx, rax                          ; fd
    mov rax, SYS_READ
    mov rdi, rbx
    lea rsi, [read_buf]
    mov rdx, 1
    syscall
    mov r9, rax                           ; bytes read
    mov rax, SYS_CLOSE
    mov rdi, rbx
    syscall
    cmp r9, 1
    jne .wifi_done
    mov al, [read_buf]
    mov [wifi_state], al
.wifi_done:

    ; Pick battery name from argv[1] or default.
    mov rdi, [rsp]
    cmp rdi, 2
    jl .use_default
    mov r15, [rsp + 16]
    jmp .have_bat
.use_default:
    lea r15, [default_bat]
.have_bat:

    ; Capacity → r12.
    lea rdi, [suf_cap]
    call read_int_field
    mov r12, rax

    ; Status (first letter) → r13.
    lea rdi, [suf_stat]
    call read_first_byte
    mov r13, rax

    ; Power_now (microwatts) → r14, energy_now (µWh) → rbx.
    ; If absent (charge-based battery), derive from voltage_now * current_now
    ; and charge_now * voltage_now.
    lea rdi, [suf_power]
    call read_int_field
    mov r14, rax
    lea rdi, [suf_energy]
    call read_int_field
    mov rbx, rax
    test r14, r14
    jnz .have_units
    test rbx, rbx
    jnz .have_units
    ; Charge-based fallback. read_int_field uses syscalls which
    ; clobber caller-saved registers, so stash each result on the
    ; stack and unpack after the last call.
    lea rdi, [suf_volt]
    call read_int_field
    push rax                              ; volt µV
    lea rdi, [suf_curr]
    call read_int_field
    push rax                              ; curr µA
    lea rdi, [suf_charge]
    call read_int_field
    pop r11                               ; curr µA
    pop r10                               ; volt µV
    mov r9, rax                           ; charge µAh

    test r10, r10
    jz .have_units
    test r11, r11
    jz .charge_only
    mov rax, r10
    mul r11                                ; rdx:rax = µV * µA
    mov rcx, 1000000
    div rcx                                ; rax = µW
    mov r14, rax
.charge_only:
    test r9, r9
    jz .have_units
    mov rax, r9
    mul r10
    mov rcx, 1000000
    div rcx
    mov rbx, rax
.have_units:

    ; Format the output. Pick a colour SGR based on state:
    ;   Charging          → light blue   (#5599ff)
    ;   Discharging <  8% → red/orange   (#ff5500)
    ;   Discharging < 15% → muted yellow (#cccc55)
    ;   else              → no SGR; segment fg from striprc applies.
    ; The reset SGR is emitted at end-of-line iff a colour was set so
    ; the next segment starts on its own colour.
    lea rdi, [out_buf]
    xor r9d, r9d                           ; r9 = 1 if we emitted a colour
    cmp r13b, 'C'
    jne .check_low
    mov rsi, .charge_sgr
    mov rcx, .charge_sgr_len
    rep movsb
    mov r9d, 1
    jmp .colour_done
.check_low:
    cmp r13b, 'D'
    jne .colour_done
    cmp r12, 8
    jge .check_warn
    mov rsi, .crit_sgr
    mov rcx, .crit_sgr_len
    rep movsb
    mov r9d, 1
    jmp .colour_done
.check_warn:
    cmp r12, 15
    jge .colour_done
    mov rsi, .warn_sgr
    mov rcx, .warn_sgr_len
    rep movsb
    mov r9d, 1
.colour_done:
    push r9                                 ; remember for the trailing reset
    mov al, r13b
    mov [rdi], al
    inc rdi
    mov byte [rdi], ' '
    inc rdi
    mov rax, r12
    mov ecx, 2
    call itoa_pad
    mov byte [rdi], '%'
    inc rdi

    ; Hours left: only if discharging AND power_now > 0.
    cmp r13b, 'D'
    jne .skip_hours
    test r14, r14
    jz .skip_hours
    ; hours = energy_now / power_now (with one decimal).
    ; Since both are µ-units, units cancel.
    mov rax, rbx
    mov rcx, 10
    mul rcx                               ; rdx:rax = energy * 10
    div r14                               ; rax = tenths of hours
    mov rcx, 10
    xor edx, edx
    div rcx                               ; rax = whole hours, rdx = tenth
    push rdx
    ; One literal space + pad whole-hours integer to 2 chars so single-
    ; digit (5h) and double-digit (12h) take the same width.
    mov byte [rdi], ' '
    inc rdi
    mov ecx, 2
    call itoa_pad
    mov byte [rdi], '.'
    inc rdi
    pop rdx
    add dl, '0'
    mov [rdi], dl
    inc rdi
    mov byte [rdi], 'h'
    inc rdi
.skip_hours:

    ; Power in W with two decimals: power_now (µW) / 1_000_000 = W.
    test r14, r14
    jz .skip_watts
    mov byte [rdi], ' '
    inc rdi
    ; centi-W = power_now / 10000  (µW → 1/100 of W).
    mov rax, r14
    xor edx, edx
    mov rcx, 10000
    div rcx
    mov rcx, 100
    xor edx, edx
    div rcx                               ; rax = whole W, rdx = hundredths
    push rdx
    mov ecx, 2                            ; pad integer part to 2 chars
    call itoa_pad
    mov byte [rdi], '.'
    inc rdi
    pop rdx
    mov rax, rdx
    mov rcx, 10
    xor edx, edx
    div rcx                               ; rax = tens digit, rdx = ones
    add al, '0'
    mov [rdi], al
    add dl, '0'
    mov [rdi+1], dl
    add rdi, 2
    mov byte [rdi], 'W'
    inc rdi
.skip_watts:

    ; Close any colour span we opened (charging / low / critical).
    pop r9
    test r9d, r9d
    jz .no_reset_sgr
    mov rsi, .reset_sgr
    mov rcx, .reset_sgr_len
    rep movsb
.no_reset_sgr:

    ; Wifi power-save indicator: " ▼" when battery-saver opted-in (the
    ; freeze-risk mode). Absent when stable (default) or state unknown,
    ; so the indicator is silent unless the user has actively chosen the
    ; risky mode. Placed after the colour reset so it inherits segment fg.
    cmp byte [wifi_state], '1'
    jne .no_wifi_glyph
    mov byte [rdi],   ' '
    mov byte [rdi+1], 0xE2                ; U+25BC ▼ = E2 96 BC
    mov byte [rdi+2], 0x96
    mov byte [rdi+3], 0xBC
    add rdi, 4
.no_wifi_glyph:

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

; Per-state SGR spans. 24-bit RGB foregrounds, parsed by strip.
.charge_sgr:     db 0x1b, "[38;2;85;153;255m"      ; charging — light blue
.charge_sgr_len  equ $ - .charge_sgr
.warn_sgr:       db 0x1b, "[38;2;204;204;85m"      ; <15% — muted yellow
.warn_sgr_len    equ $ - .warn_sgr
.crit_sgr:       db 0x1b, "[38;2;255;85;0m"        ; <8%  — red/orange
.crit_sgr_len    equ $ - .crit_sgr
.reset_sgr:      db 0x1b, "[0m"
.reset_sgr_len   equ $ - .reset_sgr

; rdi = NUL-terminated suffix (e.g. "/capacity"). Builds the full
; /sys/class/power_supply/<bat>/<suffix> path into path_buf, opens it,
; reads decimal int → rax. Returns 0 on failure.
read_int_field:
    push rbx
    push r12
    mov r12, rdi                          ; suffix
    call build_path
    mov rax, SYS_OPEN
    lea rdi, [path_buf]
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js .rif_zero
    mov rbx, rax
    mov rax, SYS_READ
    mov rdi, rbx
    lea rsi, [read_buf]
    mov rdx, 63
    syscall
    push rax
    mov rax, SYS_CLOSE
    mov rdi, rbx
    syscall
    pop rcx
    test rcx, rcx
    jle .rif_zero
    xor eax, eax
    xor edx, edx
.rif_dig:
    cmp edx, ecx
    jge .rif_done
    movzx r8, byte [read_buf + rdx]
    sub r8, '0'
    cmp r8, 9
    ja .rif_done
    imul rax, rax, 10
    add rax, r8
    inc edx
    jmp .rif_dig
.rif_done:
    pop r12
    pop rbx
    ret
.rif_zero:
    xor eax, eax
    pop r12
    pop rbx
    ret

; rdi = suffix. Reads first byte of file → al (e.g. 'D' for "Discharging").
read_first_byte:
    push rbx
    push r12
    mov r12, rdi
    call build_path
    mov rax, SYS_OPEN
    lea rdi, [path_buf]
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js .rfb_zero
    mov rbx, rax
    mov rax, SYS_READ
    mov rdi, rbx
    lea rsi, [read_buf]
    mov rdx, 1
    syscall
    push rax
    mov rax, SYS_CLOSE
    mov rdi, rbx
    syscall
    pop rax
    test rax, rax
    jle .rfb_zero
    movzx eax, byte [read_buf]
    pop r12
    pop rbx
    ret
.rfb_zero:
    mov eax, '?'
    pop r12
    pop rbx
    ret

; r12 = suffix, r15 = battery name. Builds path_buf.
build_path:
    push rbx
    lea rdi, [path_buf]
    lea rsi, [sys_pre]
    mov ecx, sys_pre_len
.bp_pre:
    test ecx, ecx
    jz .bp_bat
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jmp .bp_pre
.bp_bat:
    mov rsi, r15
.bp_bat_cp:
    mov al, [rsi]
    test al, al
    jz .bp_suf
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .bp_bat_cp
.bp_suf:
    mov rsi, r12
.bp_suf_cp:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .bp_done
    inc rsi
    inc rdi
    jmp .bp_suf_cp
.bp_done:
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
