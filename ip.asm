; ip - print "I: <iface> <ip>" matching conky's network segment.
; Reads /proc/net/route to find the interface owning the default
; route, then SIOCGIFADDR ioctl on a UDP socket to read its IPv4
; address. SSID lookup deferred (would need SIOCGIWESSID + nl80211).
;
; Build: nasm -f elf64 ip.asm -o ip.o && ld ip.o -o ip

%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_SOCKET      41
%define SYS_IOCTL       16
%define SYS_EXIT        60

%define AF_INET         2
%define SOCK_DGRAM      2
%define SIOCGIFADDR     0x8915
%define SYS_PIPE        22
%define SYS_FORK        57
%define SYS_EXECVE      59
%define SYS_WAIT4       61
%define SYS_DUP2        33

section .data
proc_route: db "/proc/net/route", 0
prefix:     db "I: "
prefix_len  equ $ - prefix

; argv for iw fork: ["iw", "dev", <iface>, "link", NULL]
iw_path:    db "/usr/sbin/iw", 0
iw_arg0:    db "iw", 0
iw_arg_dev: db "dev", 0
iw_arg_lnk: db "link", 0
ssid_marker: db "SSID:"
ssid_marker_len equ $ - ssid_marker

section .bss
route_buf: resb 4096
ifname:    resb 16
ifreq:     resb 32             ; struct ifreq: name[16] + addr[16]
iw_out:    resb 1024           ; captured stdout from `iw dev <iface> link`
display_name: resb 64          ; either SSID or iface name
out_buf:   resb 128

section .text
global _start
_start:
    ; Find default-route iface in /proc/net/route. Format:
    ;   Iface\tDest\tGateway\tFlags\t...
    ;   <name>\t00000000\t<gw>\t0003\t...
    ; Walk lines after the header; first line whose Dest column is
    ; "00000000" wins.
    mov rax, SYS_OPEN
    lea rdi, [proc_route]
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js .die
    mov r12, rax
    mov rax, SYS_READ
    mov rdi, r12
    lea rsi, [route_buf]
    mov rdx, 4095
    syscall
    mov r13, rax
    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall
    test r13, r13
    jle .die
    mov byte [route_buf + r13], 0

    ; Skip the header line (everything up to first LF).
    lea r12, [route_buf]
.skip_hdr:
    mov al, [r12]
    test al, al
    jz .die
    cmp al, 10
    je .past_hdr
    inc r12
    jmp .skip_hdr
.past_hdr:
    inc r12

    ; Walk data lines. Each: <iface>\t<dest_hex>\t...
.line_loop:
    mov al, [r12]
    test al, al
    jz .die
    ; Save line start, find tab.
    mov r14, r12
.find_tab:
    mov al, [r12]
    cmp al, 9
    je .have_tab
    cmp al, 10
    je .next_line
    test al, al
    jz .die
    inc r12
    jmp .find_tab
.have_tab:
    ; Iface name is [r14..r12). Check Dest column = "00000000".
    inc r12                               ; past tab
    cmp byte [r12 + 0], '0'
    jne .next_line
    cmp byte [r12 + 1], '0'
    jne .next_line
    cmp byte [r12 + 2], '0'
    jne .next_line
    cmp byte [r12 + 3], '0'
    jne .next_line
    cmp byte [r12 + 4], '0'
    jne .next_line
    cmp byte [r12 + 5], '0'
    jne .next_line
    cmp byte [r12 + 6], '0'
    jne .next_line
    cmp byte [r12 + 7], '0'
    jne .next_line
    ; Match! Copy iface name [r14..r12-1) into ifname (and ifreq).
    mov rcx, r12
    sub rcx, r14
    dec rcx                               ; exclude tab
    cmp rcx, 15
    jle .nm_ok
    mov rcx, 15
.nm_ok:
    lea rdi, [ifname]
    mov rsi, r14
    push rcx
.cp_nm:
    test rcx, rcx
    jz .cp_done
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jmp .cp_nm
.cp_done:
    mov byte [rdi], 0
    jmp .have_iface

.next_line:
    ; Advance to next LF + 1.
.adv_lf:
    mov al, [r12]
    test al, al
    jz .die
    cmp al, 10
    je .past_lf
    inc r12
    jmp .adv_lf
.past_lf:
    inc r12
    jmp .line_loop

.have_iface:
    ; Build ifreq: copy ifname (16 bytes, NUL-padded) into +0; zero +16..
    lea rdi, [ifreq]
    xor eax, eax
    mov ecx, 32
    rep stosb
    lea rdi, [ifreq]
    lea rsi, [ifname]
    mov ecx, 16
.cp_ifr:
    mov al, [rsi]
    test al, al
    jz .cp_ifr_done
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jnz .cp_ifr
.cp_ifr_done:
    ; Default display_name = ifname; SSID lookup may overwrite it.
    lea rdi, [display_name]
    lea rsi, [ifname]
.cp_def:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .cp_def_done
    inc rsi
    inc rdi
    jmp .cp_def
.cp_def_done:

    ; Modern wireless stacks (NetworkManager + nl80211) don't expose
    ; SSID via the legacy SIOCGIWESSID ioctl. Easiest pure-asm path:
    ; fork+exec `iw dev <iface> link`, capture its stdout, scan for
    ; "SSID: ". If iw isn't installed or the iface isn't wireless we
    ; just keep display_name = ifname.
    call fetch_ssid                       ; writes into iw_out
    call extract_ssid                     ; parses iw_out → display_name (if found)

    ; Open UDP socket + ioctl(SIOCGIFADDR).
    mov rax, SYS_SOCKET
    mov rdi, AF_INET
    mov rsi, SOCK_DGRAM
    xor edx, edx
    syscall
    test rax, rax
    js .write_no_ip
    mov r12, rax
    mov rax, SYS_IOCTL
    mov rdi, r12
    mov rsi, SIOCGIFADDR
    lea rdx, [ifreq]
    syscall
    push rax
    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall
    pop rax
    test rax, rax
    js .write_no_ip

    ; ifreq +16 = sockaddr_in: family(2), port(2), addr(4 BE bytes), pad.
    ; addr bytes at offset 16 + 4 = 20. Each byte is 0..255.
    movzx r12, byte [ifreq + 20]
    movzx r13, byte [ifreq + 21]
    movzx r14, byte [ifreq + 22]
    movzx r15, byte [ifreq + 23]

    ; Format "I: <iface> <a>.<b>.<c>.<d>\n".
    lea rdi, [out_buf]
    lea rsi, [prefix]
    mov rcx, prefix_len
    call copy_n
    lea rsi, [display_name]
    call copy_str
    mov byte [rdi], ' '
    inc rdi
    mov rax, r12
    call itoa
    mov byte [rdi], '.'
    inc rdi
    mov rax, r13
    call itoa
    mov byte [rdi], '.'
    inc rdi
    mov rax, r14
    call itoa
    mov byte [rdi], '.'
    inc rdi
    mov rax, r15
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

.write_no_ip:
    lea rdi, [out_buf]
    lea rsi, [prefix]
    mov rcx, prefix_len
    call copy_n
    lea rsi, [display_name]
    call copy_str
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

; fetch_ssid: fork+exec `iw dev <iface> link`, capture stdout into
; iw_out (NUL-terminated). On any failure iw_out[0] = 0.
fetch_ssid:
    push rbx
    push r12
    push r13
    push r14
    mov byte [iw_out], 0
    sub rsp, 16
    mov rax, SYS_PIPE
    mov rdi, rsp
    syscall
    test rax, rax
    js .fs_done_drop
    mov ebx, [rsp + 0]                    ; read end
    mov r12d, [rsp + 4]                   ; write end
    add rsp, 16
    mov rax, SYS_FORK
    syscall
    test rax, rax
    js .fs_close_both
    jz .fs_child
    ; Parent: close write end, read until EOF, wait4.
    mov r13, rax                          ; child pid
    mov rax, SYS_CLOSE
    mov edi, r12d
    syscall
    xor r14, r14                          ; bytes accumulated
.fs_read:
    mov rax, SYS_READ
    mov edi, ebx
    lea rsi, [iw_out]
    add rsi, r14
    mov rdx, 1023
    sub rdx, r14
    cmp rdx, 0
    jle .fs_eof
    syscall
    test rax, rax
    jle .fs_eof
    add r14, rax
    jmp .fs_read
.fs_eof:
    mov byte [iw_out + r14], 0
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
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.fs_close_both:
    mov rax, SYS_CLOSE
    mov edi, ebx
    syscall
    mov rax, SYS_CLOSE
    mov edi, r12d
    syscall
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.fs_done_drop:
    add rsp, 16
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.fs_child:
    mov rax, SYS_DUP2
    mov edi, r12d                         ; write end → stdout
    mov esi, 1
    syscall
    mov rax, SYS_CLOSE
    mov edi, ebx                          ; close read end in child
    syscall
    cmp r12d, 1
    je .fs_skip_close_w
    mov rax, SYS_CLOSE
    mov edi, r12d
    syscall
.fs_skip_close_w:
    sub rsp, 48
    lea rax, [iw_arg0]
    mov [rsp + 0], rax
    lea rax, [iw_arg_dev]
    mov [rsp + 8], rax
    lea rax, [ifname]
    mov [rsp + 16], rax
    lea rax, [iw_arg_lnk]
    mov [rsp + 24], rax
    mov qword [rsp + 32], 0
    mov rax, SYS_EXECVE
    lea rdi, [iw_path]
    mov rsi, rsp
    xor edx, edx                          ; envp = NULL is fine for iw
    syscall
    mov rax, SYS_EXIT
    mov edi, 127
    syscall

; extract_ssid: scan iw_out for the first "SSID:" then copy the
; following non-LF, non-leading-whitespace text into display_name.
; On miss, leaves display_name untouched.
extract_ssid:
    push rbx
    push r12
    lea r12, [iw_out]
.es_scan:
    mov al, [r12]
    test al, al
    jz .es_done
    ; Compare 5 bytes: "SSID:" (case-sensitive).
    cmp byte [r12 + 0], 'S'
    jne .es_advance
    cmp byte [r12 + 1], 'S'
    jne .es_advance
    cmp byte [r12 + 2], 'I'
    jne .es_advance
    cmp byte [r12 + 3], 'D'
    jne .es_advance
    cmp byte [r12 + 4], ':'
    jne .es_advance
    ; Match. Skip whitespace.
    add r12, 5
.es_skip_ws:
    mov al, [r12]
    cmp al, ' '
    je .es_inc
    cmp al, 9
    je .es_inc
    jmp .es_have
.es_inc:
    inc r12
    jmp .es_skip_ws
.es_have:
    ; Copy until LF / NUL into display_name, max 63 chars.
    lea rdi, [display_name]
    mov ecx, 63
.es_cp:
    test ecx, ecx
    jz .es_cp_done
    mov al, [r12]
    test al, al
    jz .es_cp_done
    cmp al, 10
    je .es_cp_done
    mov [rdi], al
    inc r12
    inc rdi
    dec ecx
    jmp .es_cp
.es_cp_done:
    mov byte [rdi], 0
.es_done:
    pop r12
    pop rbx
    ret
.es_advance:
    inc r12
    jmp .es_scan

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
