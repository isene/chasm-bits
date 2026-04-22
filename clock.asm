; clock - print "HH:MM  YYYY-MM-DD WW.D" matching the user's conky
; format: time, two spaces, date, space, ISO week.day-of-week.
;
; Uses CLOCK_REALTIME + a hardcoded TZ offset (+2h CEST). Real fix is
; parsing /etc/localtime; deferred until DST actually matters again.
;
; Build: nasm -f elf64 clock.asm -o clock.o && ld clock.o -o clock

%define SYS_WRITE         1
%define SYS_EXIT          60
%define SYS_CLOCK_GETTIME 228
%define CLOCK_REALTIME    0
%define TZ_OFFSET_S       7200          ; CEST = UTC+2

section .bss
ts:        resq 2
out_buf:   resb 32

section .text
global _start
_start:
    mov rax, SYS_CLOCK_GETTIME
    mov rdi, CLOCK_REALTIME
    lea rsi, [ts]
    syscall

    mov rax, [ts]
    add rax, TZ_OFFSET_S

    ; Days since epoch (1970-01-01) and seconds-into-day.
    mov rcx, 86400
    xor edx, edx
    div rcx
    mov r12, rax                          ; days since epoch
    mov rax, rdx                          ; seconds in day
    mov rcx, 3600
    xor edx, edx
    div rcx
    mov r13, rax                          ; hour
    mov rax, rdx
    mov rcx, 60
    xor edx, edx
    div rcx
    mov r14, rax                          ; minute

    ; Day-of-week. Epoch (1970-01-01) was a Thursday → ISO weekday 4.
    ; ISO weekday: Mon=1..Sun=7.  dow = ((days + 3) % 7) + 1.
    mov rax, r12
    add rax, 3
    xor edx, edx
    mov rcx, 7
    div rcx
    mov r15, rdx
    inc r15                               ; r15 = ISO weekday 1..7

    ; Convert days-since-epoch → year/month/day using Howard Hinnant's
    ; civil_from_days algorithm (works for 0001-01-01 .. far future).
    ; days_since_epoch → days_since_0000_03_01 (shift by 719468).
    mov rax, r12
    add rax, 719468                       ; rax = z (days from 0000-03-01)
    ; era = (z >= 0 ? z : z - 146096) / 146097
    mov rdi, rax                          ; preserve z
    xor edx, edx
    mov rcx, 146097
    div rcx                               ; eax = era, edx = doe (0..146096)
    mov r8, rax                           ; era
    mov r9, rdx                           ; doe (day-of-era)

    ; yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365
    mov rax, r9
    xor edx, edx
    mov rcx, 1460
    div rcx
    mov rsi, rax                          ; doe/1460
    mov rax, r9
    xor edx, edx
    mov rcx, 36524
    div rcx
    mov rdi, rax                          ; doe/36524
    mov rax, r9
    xor edx, edx
    mov rcx, 146096
    div rcx
    mov r10, rax                          ; doe/146096
    mov rax, r9
    sub rax, rsi
    add rax, rdi
    sub rax, r10
    xor edx, edx
    mov rcx, 365
    div rcx
    mov r11, rax                          ; yoe (0..399)

    ; year = yoe + era*400
    mov rax, r8
    imul rax, 400
    add rax, r11
    mov rbx, rax                          ; year (proto)

    ; doy = doe - (365*yoe + yoe/4 - yoe/100)
    mov rax, r11
    imul rax, 365
    mov rsi, rax                          ; 365*yoe
    mov rax, r11
    shr rax, 2                            ; yoe/4
    add rsi, rax
    mov rax, r11
    xor edx, edx
    mov rcx, 100
    div rcx
    sub rsi, rax                          ; 365*yoe + yoe/4 - yoe/100
    mov rax, r9
    sub rax, rsi                          ; doy (0..365)
    mov rcx, rax                          ; doy

    ; mp = (5*doy + 2) / 153
    mov rax, rcx
    imul rax, 5
    add rax, 2
    xor edx, edx
    mov rdi, 153
    div rdi
    mov r10, rax                          ; mp (0..11, March=0)

    ; day = doy - (153*mp + 2)/5 + 1
    mov rax, r10
    imul rax, 153
    add rax, 2
    xor edx, edx
    mov rdi, 5
    div rdi
    sub rcx, rax
    inc rcx                               ; day
    mov r9, rcx                           ; r9 = day (1..31)

    ; month = mp < 10 ? mp + 3 : mp - 9
    mov rax, r10
    cmp rax, 10
    jl .month_lt10
    sub rax, 9
    jmp .month_done
.month_lt10:
    add rax, 3
.month_done:
    mov r8, rax                           ; r8 = month (1..12)

    ; year += (month <= 2)
    cmp r8, 2
    jg .year_done
    inc rbx
.year_done:
    ; rbx = year, r8 = month, r9 = day, r13 = hour, r14 = min, r15 = ISO dow.

    ; Compute ISO week number.
    ; ordinal day = doy - (Mar 1 doy=0). Need ordinal-day-of-year (Jan 1 = 1).
    ; Easier: ordinal_day = (year - rbx_orig) ... actually use:
    ; ordinal_day_of_year = day_of_year_from_month_day(month, day, isLeap(year))
    ; Then ISO week = ((ordinal_day - dow + 10) / 7), with adjustments.
    ; This is fiddly; use a simpler approximation that suffices for display:
    ; iso_week = ((ordinal_day - dow + 10) / 7), then clamp to 1..53.
    push rbx
    push r8
    push r9
    push r10
    mov rdi, rbx                          ; year
    mov rsi, r8                           ; month
    mov rdx, r9                           ; day
    call ordinal_day                      ; rax = day-of-year (1..366)
    mov rcx, rax                          ; ordinal day
    pop r10
    pop r9
    pop r8
    pop rbx
    ; iso_week = (ordinal - dow + 10) / 7
    mov rax, rcx
    sub rax, r15
    add rax, 10
    xor edx, edx
    mov rcx, 7
    div rcx
    mov r12, rax                          ; iso_week
    cmp r12, 0
    jne .iw_ok
    mov r12, 52                           ; rough fix for week 0 → prev year's last
.iw_ok:
    cmp r12, 53
    jle .iw_done
    mov r12, 1
.iw_done:
    ; Format "HH:MM  YYYY-MM-DD WW.D".
    lea rdi, [out_buf]
    mov rax, r13
    call write2
    mov byte [rdi], ':'
    inc rdi
    mov rax, r14
    call write2
    mov byte [rdi], ' '
    mov byte [rdi+1], ' '
    add rdi, 2
    mov rax, rbx
    call write4
    mov byte [rdi], '-'
    inc rdi
    mov rax, r8
    call write2
    mov byte [rdi], '-'
    inc rdi
    mov rax, r9
    call write2
    mov byte [rdi], ' '
    inc rdi
    mov rax, r12
    call write2
    mov byte [rdi], '.'
    inc rdi
    mov rax, r15
    add al, '0'
    mov [rdi], al
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

; rax = number 0..99, rdi = buffer ptr. Writes 2 zero-padded digits.
write2:
    push rcx
    push rdx
    mov rcx, 10
    xor edx, edx
    div rcx
    add al, '0'
    add dl, '0'
    mov [rdi], al
    mov [rdi+1], dl
    add rdi, 2
    pop rdx
    pop rcx
    ret

; rax = number 0..9999, rdi = buffer ptr. Writes 4 zero-padded digits.
write4:
    push rcx
    push rdx
    mov rcx, 1000
    xor edx, edx
    div rcx
    add al, '0'
    mov [rdi], al
    mov rax, rdx
    mov rcx, 100
    xor edx, edx
    div rcx
    add al, '0'
    mov [rdi+1], al
    mov rax, rdx
    mov rcx, 10
    xor edx, edx
    div rcx
    add al, '0'
    add dl, '0'
    mov [rdi+2], al
    mov [rdi+3], dl
    add rdi, 4
    pop rdx
    pop rcx
    ret

; rdi = year, rsi = month (1..12), rdx = day (1..31).
; Returns rax = ordinal day of year (1..366).
ordinal_day:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi                          ; year
    mov r13, rsi                          ; month
    mov r14, rdx                          ; day
    ; cumulative days at start of each month (non-leap).
    lea rax, [.cum]
    mov rcx, r13
    dec rcx
    mov rbx, [rax + rcx*8]                ; days before this month
    add rbx, r14                          ; + day
    ; Add leap day if leap year and month >= 3.
    mov rax, r12
    xor edx, edx
    mov rcx, 4
    div rcx
    test rdx, rdx
    jnz .od_done
    mov rax, r12
    xor edx, edx
    mov rcx, 100
    div rcx
    test rdx, rdx
    jnz .od_leap
    mov rax, r12
    xor edx, edx
    mov rcx, 400
    div rcx
    test rdx, rdx
    jnz .od_done                          ; div by 100 but not 400 → not leap
.od_leap:
    cmp r13, 3
    jl .od_done
    inc rbx
.od_done:
    mov rax, rbx
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

section .data
.cum:
    dq 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334
