; net - wifi name, public IP, link quality and download speed for strip's
; net segment, in one fixed-width line:
;
;   HomeWifi      203.0.113.7  70% 104M
;
; The wifi name and signal come straight from the kernel over nl80211
; (generic netlink): no iw, no awk, nothing forked on a normal run. The
; public IP and the speed live in cache files. They are refreshed only
; when the network changes (another SSID, or the VPN going up or down):
; then a background child runs curl, once for the IP and, on a new SSID,
; once for a 10 MB speed test. The line printed now uses the old caches;
; the next run shows the new values.
;
; Captive portals: until the IP lookup gets a real address, the IP reads
; "offline" and the lookup is retried every run (30 s). A new network's
; line never shows the old network's IP. When a lookup succeeds, the
; child sends strip SIGURG, so strip reruns every segment at once: the IP
; and the ping appear within seconds of getting through the portal. The
; speed test waits until the Internet works.
;
; Replaces a bash net-status + essid.sh + netspeed.sh that started 21
; programs and used 86 ms of CPU every 30 s, and asked ifconfig.me for
; the IP about once a minute, waking the wifi radio each time.
;
; Caches: /tmp/strip_ip_cache, /tmp/strip_speed_cache, /tmp/strip_last_ssid,
; /tmp/strip_net_key (the SSID and VPN state last refreshed for).
;
; Build: nasm -f elf64 net.asm -o net.o && ld net.o -o net

%define SYS_READ    0
%define SYS_WRITE   1
%define SYS_OPEN    2
%define SYS_CLOSE   3
%define SYS_PIPE    22
%define SYS_DUP2    33
%define SYS_SOCKET  41
%define SYS_FORK    57
%define SYS_EXECVE  59
%define SYS_EXIT    60
%define SYS_WAIT4   61
%define SYS_UNLINK  87
%define SYS_KILL    62
%define SYS_GETPPID 110
%define SYS_SETSID  112

%define SIGURG      23
%define O_RDWR      2
%define O_WRONLY    1
%define O_CREAT     0x40
%define O_TRUNC     0x200

%define AF_NETLINK      16
%define SOCK_RAW        3
%define SOCK_CLOEXEC    0x80000
%define NETLINK_GENERIC 16

%define NLMSG_ERROR     2
%define NLMSG_DONE      3
%define GENL_ID_CTRL    16
%define CTRL_ATTR_FAMILY_ID 1
%define NL80211_ATTR_IFINDEX  3
%define NL80211_ATTR_IFTYPE   5
%define NL80211_ATTR_STA_INFO 21
%define NL80211_ATTR_SSID     52
%define NL80211_STA_INFO_SIGNAL 7
%define NL80211_IFTYPE_STATION  2

%define SSID_W      13             ; display width of the wifi name
%define LINE_W      27             ; display width of the whole line
%define NLBUF_SZ    32768

section .data
; CTRL_CMD_GETFAMILY "nl80211": nlmsghdr + genlmsghdr + one attribute.
fam_req:
    dd 32                          ; nlmsg_len
    dw GENL_ID_CTRL, 1             ; type, flags = NLM_F_REQUEST
    dd 1, 0                        ; seq, pid
    db 3, 1                        ; cmd = GETFAMILY, version
    dw 0
    dw 12, 2                       ; nla_len, CTRL_ATTR_FAMILY_NAME
    db "nl80211", 0
; NL80211_CMD_GET_INTERFACE, dump. Type is patched to the family id.
iface_req:
    dd 20
    dw 0, 0x301                    ; NLM_F_REQUEST | NLM_F_DUMP
    dd 2, 0
    db 5, 0                        ; cmd = GET_INTERFACE
    dw 0
; NL80211_CMD_GET_STATION, dump, for one interface (ifindex at +24).
sta_req:
    dd 28
    dw 0, 0x301
    dd 3, 0
    db 17, 0                       ; cmd = GET_STATION
    dw 0
    dw 8, NL80211_ATTR_IFINDEX
    dd 0

offline:     db "offline", 10
ip_cache:    db "/tmp/strip_ip_cache", 0
speed_cache: db "/tmp/strip_speed_cache", 0
ssid_cache:  db "/tmp/strip_last_ssid", 0
key_path:    db "/tmp/strip_net_key", 0
dev_null:    db "/dev/null", 0
ppp_path:    db "/sys/class/net/ppp0/operstate", 0
%define PPP_DIGIT 18               ; offset of the '0' in ppp_path

nowifi:      db "NoWiFi"
dots:        db "..."
ellipsis:    db 0xE2, 0x80, 0xA6   ; U+2026, one column wide

curl_path:   db "/usr/bin/curl", 0
a_curl:      db "curl", 0
a_4:         db "-4", 0
a_s:         db "-s", 0
a_mt:        db "--max-time", 0
a_5:         db "5", 0
a_10:        db "10", 0
a_w:         db "-w", 0
a_fmt:       db "%{speed_download}", 0
a_o:         db "-o", 0
ip_url:      db "http://ifconfig.me", 0
sp_url:      db "https://speed.cloudflare.com/__down?bytes=10000000", 0
ip_argv:     dq a_curl, a_4, a_s, a_mt, a_5, ip_url, 0
sp_argv:     dq a_curl, a_4, a_s, a_w, a_fmt, a_o, dev_null, a_mt, a_10, sp_url, 0

section .bss
envp:        resq 1
strip_pid:   resd 1                ; our parent when it is strip, else 0
procpath:    resb 32
nlfd:        resd 1
family:      resd 1
ifindex:     resd 1
signal:      resd 1                ; dBm, signed
have_signal: resb 1
ssid:        resb 36
ssid_len:    resd 1
cand_idx:    resd 1                ; per-message scratch while parsing
cand_type:   resd 1
cand_ssid:   resq 1
cand_slen:   resd 1
key_cur:     resb 64
key_len:     resd 1
key_old:     resb 64
filebuf:     resb 256
curlbuf:     resb 256
san:         resb 40
out:         resb 256
nlbuf:       resb NLBUF_SZ

section .text
global _start
_start:
    mov rax, [rsp]                 ; argc
    lea rcx, [rsp + 16 + rax*8]    ; envp = argv + argc + 1
    mov [envp], rcx

    call wifi_query
    call build_key
    call key_changed               ; eax = 1 if the network changed
    test eax, eax
    jz .print
    ; The last network's IP must not show as if we were online. An
    ; "offline" from a failed lookup stays until one succeeds.
    lea rdi, [ip_cache]
    lea rsi, [curlbuf]
    mov edx, 32
    call read_file
    call valid_ip
    test eax, eax
    jz .keep_ip
    mov eax, SYS_UNLINK
    lea rdi, [ip_cache]
    syscall
.keep_ip:
    lea rdi, [key_path]
    lea rsi, [key_cur]
    mov edx, [key_len]
    call write_file                ; claim it first: no second refresh
    cmp dword [ssid_len], 0
    je .print                      ; no wifi: nothing to look up
    call ssid_is_new               ; the last network's speed is not ours
    test eax, eax
    jz .keep_speed
    mov eax, SYS_UNLINK
    lea rdi, [speed_cache]
    syscall
.keep_speed:
    call find_strip
    call spawn_refresh
.print:
    call format_line               ; rdx = bytes in out
    mov eax, SYS_WRITE
    mov edi, 1
    lea rsi, [out]
    syscall
    mov eax, SYS_EXIT
    xor edi, edi
    syscall

; ---------------------------------------------------------------------------
; wifi_query - fills ssid/ssid_len and signal/have_signal from nl80211.
; Leaves ssid_len 0 when there is no connected station interface.
; ---------------------------------------------------------------------------
wifi_query:
    push rbx
    push r12
    push r13
    mov eax, SYS_SOCKET
    mov edi, AF_NETLINK
    mov esi, SOCK_RAW | SOCK_CLOEXEC
    mov edx, NETLINK_GENERIC
    syscall
    test eax, eax
    js .wq_ret
    mov [nlfd], eax

    ; Resolve the nl80211 family id.
    lea rsi, [fam_req]
    mov edx, 32
    call nl_send
    call nl_recv                   ; rax = bytes
    cmp rax, 20
    jl .wq_close
    cmp word [nlbuf + 4], GENL_ID_CTRL
    jne .wq_close
    lea rbx, [nlbuf + 20]          ; first attribute
    mov r12d, [nlbuf]
    lea r12, [nlbuf + r12]         ; end of message
.wq_fam_attr:
    lea rax, [rbx + 4]
    cmp rax, r12
    ja .wq_close
    movzx ecx, word [rbx]          ; nla_len
    cmp ecx, 4
    jb .wq_close
    movzx eax, word [rbx + 2]
    and eax, 0x3fff
    cmp eax, CTRL_ATTR_FAMILY_ID
    je .wq_fam_found
    add ecx, 3
    and ecx, ~3
    add rbx, rcx
    jmp .wq_fam_attr
.wq_fam_found:
    movzx eax, word [rbx + 4]
    mov [family], eax
    mov [iface_req + 4], ax
    mov [sta_req + 4], ax

    ; Find the first station-type interface and its SSID.
    lea rsi, [iface_req]
    mov edx, 20
    call nl_send
.wq_if_recv:
    call nl_recv
    test rax, rax
    jle .wq_close
    lea rbx, [nlbuf]
    lea r13, [nlbuf + rax]         ; end of datagram
.wq_if_msg:
    lea rax, [rbx + 16]
    cmp rax, r13
    ja .wq_if_recv
    mov r12d, [rbx]                ; nlmsg_len
    cmp r12d, 16
    jb .wq_close
    movzx eax, word [rbx + 4]
    cmp eax, NLMSG_DONE
    je .wq_if_done
    cmp eax, NLMSG_ERROR
    je .wq_close
    cmp eax, [family]
    jne .wq_if_next
    mov dword [cand_type], -1
    mov dword [cand_slen], 0
    lea rdi, [rbx + 20]
    lea rsi, [rbx + r12]
    call parse_iface_attrs
    cmp dword [ifindex], 0
    jne .wq_if_next                ; already have one
    cmp dword [cand_type], NL80211_IFTYPE_STATION
    jne .wq_if_next
    mov eax, [cand_idx]
    mov [ifindex], eax
    mov ecx, [cand_slen]
    cmp ecx, 32
    jbe .wq_ssid_len_ok
    mov ecx, 32
.wq_ssid_len_ok:
    mov [ssid_len], ecx
    mov rsi, [cand_ssid]
    lea rdi, [ssid]
    rep movsb
.wq_if_next:
    add r12d, 3
    and r12d, ~3
    add rbx, r12
    jmp .wq_if_msg
.wq_if_done:
    cmp dword [ifindex], 0
    je .wq_close
    cmp dword [ssid_len], 0
    je .wq_close                   ; not connected: no signal to read

    ; Signal of the access point this interface is connected to.
    mov eax, [ifindex]
    mov [sta_req + 24], eax
    lea rsi, [sta_req]
    mov edx, 28
    call nl_send
.wq_st_recv:
    call nl_recv
    test rax, rax
    jle .wq_close
    lea rbx, [nlbuf]
    lea r13, [nlbuf + rax]
.wq_st_msg:
    lea rax, [rbx + 16]
    cmp rax, r13
    ja .wq_st_recv
    mov r12d, [rbx]
    cmp r12d, 16
    jb .wq_close
    movzx eax, word [rbx + 4]
    cmp eax, NLMSG_DONE
    je .wq_close
    cmp eax, NLMSG_ERROR
    je .wq_close
    cmp eax, [family]
    jne .wq_st_next
    cmp byte [have_signal], 0
    jne .wq_st_next
    lea rdi, [rbx + 20]
    lea rsi, [rbx + r12]
    call parse_station_attrs
.wq_st_next:
    add r12d, 3
    and r12d, ~3
    add rbx, r12
    jmp .wq_st_msg

.wq_close:
    mov eax, SYS_CLOSE
    mov edi, [nlfd]
    syscall
.wq_ret:
    pop r13
    pop r12
    pop rbx
    ret

; rdi = first attribute, rsi = end. Sets cand_idx, cand_type, cand_ssid/slen.
parse_iface_attrs:
.pia_loop:
    lea rax, [rdi + 4]
    cmp rax, rsi
    ja .pia_ret
    movzx ecx, word [rdi]
    cmp ecx, 4
    jb .pia_ret
    movzx eax, word [rdi + 2]
    and eax, 0x3fff
    cmp eax, NL80211_ATTR_IFINDEX
    jne .pia_not_idx
    mov edx, [rdi + 4]
    mov [cand_idx], edx
    jmp .pia_next
.pia_not_idx:
    cmp eax, NL80211_ATTR_IFTYPE
    jne .pia_not_type
    mov edx, [rdi + 4]
    mov [cand_type], edx
    jmp .pia_next
.pia_not_type:
    cmp eax, NL80211_ATTR_SSID
    jne .pia_next
    lea rdx, [rdi + 4]
    mov [cand_ssid], rdx
    lea edx, [ecx - 4]
    mov [cand_slen], edx
.pia_next:
    add ecx, 3
    and ecx, ~3
    add rdi, rcx
    jmp .pia_loop
.pia_ret:
    ret

; rdi = first attribute, rsi = end. Finds STA_INFO > SIGNAL.
parse_station_attrs:
.psa_loop:
    lea rax, [rdi + 4]
    cmp rax, rsi
    ja .psa_ret
    movzx ecx, word [rdi]
    cmp ecx, 4
    jb .psa_ret
    movzx eax, word [rdi + 2]
    and eax, 0x3fff
    cmp eax, NL80211_ATTR_STA_INFO
    jne .psa_next
    lea r8, [rdi + 4]              ; nested attributes
    lea r9, [rdi + rcx]            ; end of the nest
.psa_inner:
    lea rax, [r8 + 4]
    cmp rax, r9
    ja .psa_next
    movzx edx, word [r8]
    cmp edx, 4
    jb .psa_next
    movzx eax, word [r8 + 2]
    and eax, 0x3fff
    cmp eax, NL80211_STA_INFO_SIGNAL
    jne .psa_inner_next
    movsx eax, byte [r8 + 4]
    mov [signal], eax
    mov byte [have_signal], 1
    ret
.psa_inner_next:
    add edx, 3
    and edx, ~3
    add r8, rdx
    jmp .psa_inner
.psa_next:
    add ecx, 3
    and ecx, ~3
    add rdi, rcx
    jmp .psa_loop
.psa_ret:
    ret

; rsi = message, edx = length.
nl_send:
    mov eax, SYS_WRITE
    mov edi, [nlfd]
    syscall
    ret

; rax = bytes read into nlbuf (<= 0 on error).
nl_recv:
    mov eax, SYS_READ
    mov edi, [nlfd]
    lea rsi, [nlbuf]
    mov edx, NLBUF_SZ
    syscall
    ret

; ---------------------------------------------------------------------------
; build_key - key_cur = ssid + '|' + ('1' if a ppp VPN link is up, else '0').
; ---------------------------------------------------------------------------
build_key:
    lea rdi, [key_cur]
    lea rsi, [ssid]
    mov ecx, [ssid_len]
    rep movsb
    mov byte [rdi], '|'
    inc rdi
    push rdi
    call vpn_up                    ; al = '0' / '1'
    pop rdi
    mov [rdi], al
    inc rdi
    lea rax, [key_cur]
    sub rdi, rax
    mov [key_len], edi
    ret

; al = '1' if /sys/class/net/ppp0..3/operstate exists and is not "down".
vpn_up:
    push rbx
    mov bl, '0'
.vu_loop:
    mov [ppp_path + PPP_DIGIT], bl
    lea rdi, [ppp_path]
    lea rsi, [filebuf]
    mov edx, 16
    call read_file
    test eax, eax
    jz .vu_next
    cmp dword [filebuf], 'down'
    jne .vu_yes
.vu_next:
    inc bl
    cmp bl, '3'
    jbe .vu_loop
    mov al, '0'
    pop rbx
    ret
.vu_yes:
    mov al, '1'
    pop rbx
    ret

; eax = 1 if key_cur differs from the stored key.
key_changed:
    lea rdi, [key_path]
    lea rsi, [key_old]
    mov edx, 63
    call read_file
    cmp eax, [key_len]
    jne .kc_yes
    mov ecx, eax
    lea rsi, [key_cur]
    lea rdi, [key_old]
    repe cmpsb
    jne .kc_yes
    xor eax, eax
    ret
.kc_yes:
    mov eax, 1
    ret

; ---------------------------------------------------------------------------
; spawn_refresh - fork a detached child that refreshes the IP (and, on a
; new SSID, the speed). The parent returns at once. The child moves its
; stdio to /dev/null, so strip's pipe closes when the parent exits.
; ---------------------------------------------------------------------------
spawn_refresh:
    mov eax, SYS_FORK
    syscall
    test eax, eax
    jnz .sr_ret                    ; parent (or fork failed)
    mov eax, SYS_SETSID
    syscall
    mov eax, SYS_OPEN
    lea rdi, [dev_null]
    mov esi, O_RDWR
    xor edx, edx
    syscall
    mov ebx, eax
    xor r12d, r12d
.sr_dup:
    mov eax, SYS_DUP2
    mov edi, ebx
    mov esi, r12d
    syscall
    inc r12d
    cmp r12d, 3
    jb .sr_dup

    ; Public IP.
    lea rdi, [ip_argv]
    call run_curl                  ; eax = bytes in curlbuf
    call valid_ip                  ; eax = length of a valid IPv4, or 0
    test eax, eax
    jz .sr_ip_fail
    mov byte [curlbuf + rax], 10
    lea edx, [eax + 1]
    lea rdi, [ip_cache]
    lea rsi, [curlbuf]
    call write_file
    call poke_strip                ; show the IP and a fresh ping now
    jmp .sr_speed
.sr_ip_fail:
    ; No Internet yet (a captive portal, or none at all): say so, and
    ; forget the key so the next run tries again. No speed test.
    lea rdi, [ip_cache]
    lea rsi, [offline]
    mov edx, 8
    call write_file
    mov eax, SYS_UNLINK
    lea rdi, [key_path]
    syscall
    jmp .sr_exit

.sr_speed:
    ; Speed test only when the SSID itself changed, not for a VPN switch.
    call ssid_is_new
    test eax, eax
    jz .sr_exit
.sr_new_ssid:
    mov ecx, [ssid_len]
    lea rsi, [ssid]
    lea rdi, [filebuf]
    rep movsb
    mov byte [rdi], 10
    mov edx, [ssid_len]
    inc edx
    lea rdi, [ssid_cache]
    lea rsi, [filebuf]
    call write_file
    lea rdi, [sp_argv]
    call run_curl
    ; curl prints bytes per second, e.g. "13081447.000".
    xor eax, eax
    xor ecx, ecx
.sr_num:
    movzx edx, byte [curlbuf + rcx]
    sub edx, '0'
    cmp edx, 9
    ja .sr_num_done
    imul rax, rax, 10
    add rax, rdx
    inc ecx
    cmp ecx, 20
    jb .sr_num
.sr_num_done:
    lea rdi, [filebuf]
    test rax, rax
    jz .sr_unknown
    shl rax, 3
    xor edx, edx
    mov ecx, 1000000
    div rcx                        ; Mbit/s
    call put_uint
    mov byte [rdi], 'M'
    inc rdi
    jmp .sr_speed_write
.sr_unknown:
    mov byte [rdi], '?'
    inc rdi
.sr_speed_write:
    mov byte [rdi], 10
    inc rdi
    lea rsi, [filebuf]
    mov rdx, rdi
    sub rdx, rsi
    lea rdi, [speed_cache]
    call write_file
    call poke_strip
.sr_exit:
    mov eax, SYS_EXIT
    xor edi, edi
    syscall
.sr_ret:
    ret

; rdi = argv. Runs curl with stdout to a pipe; eax = bytes in curlbuf.
run_curl:
    push rbx
    push r12
    push r13
    mov r13, rdi
    sub rsp, 16
    mov eax, SYS_PIPE
    mov rdi, rsp
    syscall
    test eax, eax
    js .rc_fail
    mov eax, SYS_FORK
    syscall
    test eax, eax
    js .rc_fail
    jnz .rc_parent
    mov eax, SYS_DUP2              ; child: write end becomes stdout
    mov edi, [rsp + 4]
    mov esi, 1
    syscall
    mov eax, SYS_EXECVE
    lea rdi, [curl_path]
    mov rsi, r13
    mov rdx, [envp]
    syscall
    mov eax, SYS_EXIT
    mov edi, 127
    syscall
.rc_parent:
    mov r12d, eax                  ; pid
    mov eax, SYS_CLOSE
    mov edi, [rsp + 4]
    syscall
    xor ebx, ebx
.rc_read:
    cmp ebx, 255
    jae .rc_read_done
    mov eax, SYS_READ
    mov edi, [rsp]
    lea rsi, [curlbuf + rbx]
    mov edx, 255
    sub edx, ebx
    syscall
    test eax, eax
    jle .rc_read_done
    add ebx, eax
    jmp .rc_read
.rc_read_done:
    mov eax, SYS_CLOSE
    mov edi, [rsp]
    syscall
    mov eax, SYS_WAIT4
    mov edi, r12d
    xor esi, esi
    xor edx, edx
    xor r10d, r10d
    syscall
    mov byte [curlbuf + rbx], 0
    mov eax, ebx
    add rsp, 16
    pop r13
    pop r12
    pop rbx
    ret
.rc_fail:
    xor eax, eax
    add rsp, 16
    pop r13
    pop r12
    pop rbx
    ret

; find_strip - strip_pid = our parent if it is strip (strip execs us
; directly, so its /proc comm reads "strip" or "tile-strip"), else 0.
; Run by hand from a shell, net must not signal that shell.
find_strip:
    push r12
    mov eax, SYS_GETPPID
    syscall
    mov r12d, eax
    lea rdi, [procpath]
    mov dword [rdi], '/pro'
    mov word [rdi + 4], 'c/'
    add rdi, 6
    call put_uint
    mov dword [rdi], '/com'
    mov word [rdi + 4], 'm'
    lea rdi, [procpath]
    lea rsi, [filebuf]
    mov edx, 32
    call read_file
    cmp eax, 6
    jb .fs_ret
    cmp dword [filebuf + rax - 6], 'stri'
    jne .fs_ret
    cmp word [filebuf + rax - 2], 0x0A70   ; "p\n"
    jne .fs_ret
    mov [strip_pid], r12d
.fs_ret:
    pop r12
    ret

; ssid_is_new - eax = 1 when the wifi name differs from the one the last
; speed test was for (ssid_cache), else 0.
ssid_is_new:
    lea rdi, [ssid_cache]
    lea rsi, [filebuf]
    mov edx, 40
    call read_file
    mov ecx, [ssid_len]
    lea edx, [ecx + 1]
    cmp eax, edx
    jne .sn_yes
    cmp byte [filebuf + rcx], 10
    jne .sn_yes
    lea rsi, [ssid]
    lea rdi, [filebuf]
    repe cmpsb
    jne .sn_yes
    xor eax, eax
    ret
.sn_yes:
    mov eax, 1
    ret

; poke_strip - SIGURG to strip: rerun every segment now.
poke_strip:
    mov edi, [strip_pid]
    test edi, edi
    jz .pk_ret
    mov eax, SYS_KILL
    mov esi, SIGURG
    syscall
.pk_ret:
    ret

; eax = bytes in curlbuf. Returns eax = length of the leading IPv4
; (digits and three dots, 7..15 chars, nothing else before a newline or
; the end), else 0. Guards against a captive portal's HTML.
valid_ip:
    mov r8d, eax
    xor ecx, ecx
    xor edx, edx                   ; dots
.vi_loop:
    cmp ecx, r8d
    jae .vi_end
    movzx eax, byte [curlbuf + rcx]
    cmp al, 10
    je .vi_end
    cmp al, '.'
    jne .vi_digit
    inc edx
    jmp .vi_next
.vi_digit:
    sub al, '0'
    cmp al, 9
    ja .vi_bad
.vi_next:
    inc ecx
    cmp ecx, 15
    ja .vi_bad
    jmp .vi_loop
.vi_end:
    cmp ecx, 7
    jb .vi_bad
    cmp edx, 3
    jne .vi_bad
    mov eax, ecx
    ret
.vi_bad:
    xor eax, eax
    ret

; ---------------------------------------------------------------------------
; format_line - builds the segment text in out; rdx = byte count.
; ---------------------------------------------------------------------------
format_line:
    push rbx
    push r12
    lea rdi, [out]
    xor r12d, r12d                 ; extra bytes beyond display columns

    ; Wifi name: printable ASCII, '#' shown as '@', padded to SSID_W.
    mov ecx, [ssid_len]
    test ecx, ecx
    jnz .fl_name
    lea rsi, [nowifi]
    mov ecx, 6
    rep movsb
    mov ecx, 6
    jmp .fl_name_pad
.fl_name:
    lea rsi, [ssid]
    lea rdx, [san]
    xor ebx, ebx                   ; sanitized length
.fl_san:
    test ecx, ecx
    jz .fl_san_done
    mov al, [rsi]
    inc rsi
    dec ecx
    cmp al, '#'
    jne .fl_san_chk
    mov al, '@'
.fl_san_chk:
    cmp al, 0x20
    jb .fl_san
    cmp al, 0x7e
    ja .fl_san
    mov [rdx + rbx], al
    inc ebx
    jmp .fl_san
.fl_san_done:
    lea rsi, [san]
    cmp ebx, SSID_W
    jbe .fl_name_fits
    mov ecx, SSID_W - 1            ; too long: 12 characters and "…"
    rep movsb
    lea rsi, [ellipsis]
    mov ecx, 3
    rep movsb
    add r12d, 2
    mov ecx, SSID_W
    jmp .fl_name_pad
.fl_name_fits:
    mov ecx, ebx
    rep movsb
    mov ecx, ebx
.fl_name_pad:
    cmp ecx, SSID_W
    jae .fl_ip
    mov byte [rdi], ' '
    inc rdi
    inc ecx
    jmp .fl_name_pad

.fl_ip:
    mov byte [rdi], ' '
    inc rdi
    push rdi
    lea rdi, [ip_cache]
    lea rsi, [curlbuf]
    mov edx, 32
    call read_file
    call valid_ip                  ; (r8d = bytes read)
    pop rdi
    test eax, eax
    jz .fl_ip_none
    mov ecx, eax
    lea rsi, [curlbuf]
    rep movsb
    jmp .fl_ip_done
.fl_ip_none:
    cmp r8d, 7
    jb .fl_ip_dots
    cmp dword [curlbuf], 'offl'
    jne .fl_ip_dots
    cmp dword [curlbuf + 3], 'line'
    jne .fl_ip_dots
    lea rsi, [offline]
    mov ecx, 7
    rep movsb
    jmp .fl_ip_done
.fl_ip_dots:
    lea rsi, [dots]
    mov ecx, 3
    rep movsb
.fl_ip_done:
    mov byte [rdi], ' '
    inc rdi

    ; Link quality: -30 dBm = 100 %, -90 dBm = 0 %.
    xor eax, eax
    cmp byte [have_signal], 0
    je .fl_pct
    mov eax, [signal]
    add eax, 90
    imul eax, eax, 100
    cdq
    mov ecx, 60
    idiv ecx
    test eax, eax
    jns .fl_pct_lo
    xor eax, eax
.fl_pct_lo:
    cmp eax, 100
    jle .fl_pct
    mov eax, 100
.fl_pct:
    cmp eax, 100
    je .fl_pct_num
    mov byte [rdi], ' '            ; keep the columns when it drops below 100
    inc rdi
.fl_pct_num:
    call put_uint
    mov byte [rdi], '%'
    mov byte [rdi + 1], ' '
    add rdi, 2

    ; Speed from its cache, first line, at most 8 printable characters.
    push rdi
    lea rdi, [speed_cache]
    lea rsi, [filebuf]
    mov edx, 32
    call read_file
    pop rdi
    xor ecx, ecx
.fl_sp:
    cmp ecx, eax
    jae .fl_sp_done
    cmp ecx, 8
    jae .fl_sp_done
    mov dl, [filebuf + rcx]
    cmp dl, 0x21
    jb .fl_sp_done
    cmp dl, 0x7e
    ja .fl_sp_done
    mov [rdi], dl
    inc rdi
    inc ecx
    jmp .fl_sp
.fl_sp_done:
    test ecx, ecx
    jnz .fl_pad
    mov byte [rdi], '?'
    inc rdi

.fl_pad:
    ; Pad the whole line to LINE_W display columns.
    lea rdx, [out]
    mov rax, rdi
    sub rax, rdx
    sub eax, r12d                  ; display columns so far
.fl_pad_loop:
    cmp eax, LINE_W
    jae .fl_done
    mov byte [rdi], ' '
    inc rdi
    inc eax
    jmp .fl_pad_loop
.fl_done:
    lea rdx, [out]
    sub rdi, rdx
    mov rdx, rdi
    pop r12
    pop rbx
    ret

; ---------------------------------------------------------------------------
; Small helpers.
; ---------------------------------------------------------------------------

; rdi = path, rsi = buffer, edx = max bytes. eax = bytes read (0 on error).
read_file:
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov r13d, edx
    mov eax, SYS_OPEN
    xor esi, esi
    xor edx, edx
    syscall
    test eax, eax
    js .rf_fail
    mov ebx, eax
    mov eax, SYS_READ
    mov edi, ebx
    mov rsi, r12
    mov edx, r13d
    syscall
    push rax
    mov eax, SYS_CLOSE
    mov edi, ebx
    syscall
    pop rax
    test eax, eax
    jns .rf_ret
.rf_fail:
    xor eax, eax
.rf_ret:
    pop r13
    pop r12
    pop rbx
    ret

; rdi = path, rsi = data, edx = bytes. Replaces the file's contents.
write_file:
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov r13d, edx
    mov eax, SYS_OPEN
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, 0o644
    syscall
    test eax, eax
    js .wf_ret
    mov ebx, eax
    mov eax, SYS_WRITE
    mov edi, ebx
    mov rsi, r12
    mov edx, r13d
    syscall
    mov eax, SYS_CLOSE
    mov edi, ebx
    syscall
.wf_ret:
    pop r13
    pop r12
    pop rbx
    ret

; eax = value, rdi = destination. Writes the decimal digits, advances rdi.
put_uint:
    push rbx
    mov ebx, 10
    sub rsp, 16
    lea rsi, [rsp + 15]
    mov ecx, 0
.pu_loop:
    xor edx, edx
    div ebx
    add dl, '0'
    mov [rsi], dl
    dec rsi
    inc ecx
    test eax, eax
    jnz .pu_loop
    inc rsi
    rep movsb
    add rsp, 16
    pop rbx
    ret
