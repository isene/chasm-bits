; ════════════════════════════════════════════════════════════════════════
; wintitle — print the focused window's title to stdout.
;
;   Usage: wintitle [--length N]
;
; Asks the X server for the focused window via GetInputFocus, then reads
; _NET_WM_NAME (UTF-8) — falling back to WM_NAME (legacy STRING) if the
; modern atom is unset. Prints the result to stdout, optionally
; truncated to N display chars with a mid-string … so the suffix
; (file extension, app identity) survives.
;
; Designed to be spawned by strip on a refresh interval. Each invocation
; is one-shot: connect → query → print → exit.
; ════════════════════════════════════════════════════════════════════════

%define SYS_READ          0
%define SYS_WRITE         1
%define SYS_OPEN          2
%define SYS_CLOSE         3
%define SYS_SOCKET        41
%define SYS_CONNECT       42
%define SYS_EXIT          60

%define AF_UNIX           1
%define SOCK_STREAM       1

; X11 opcodes we use.
%define X11_INTERN_ATOM    16
%define X11_GET_PROPERTY   20
%define X11_GET_INPUT_FOCUS 43

; Predefined X11 atoms (don't need InternAtom).
%define ATOM_STRING        31
%define ATOM_WM_NAME       39
%define ATOM_ANY           0

%define MAX_TITLE          1024
%define DEFAULT_LEN        60

section .data

x11_sock_pre:    db "/tmp/.X11-unix/X", 0
auth_name:       db "MIT-MAGIC-COOKIE-1"
auth_name_len    equ 18

atom_str_net_wm_name:  db "_NET_WM_NAME"
atom_str_net_wm_name_len equ $ - atom_str_net_wm_name

atom_str_utf8_string:  db "UTF8_STRING"
atom_str_utf8_string_len equ $ - atom_str_utf8_string

ellipsis:        db 0xE2, 0x80, 0xA6      ; "…" UTF-8 (3 bytes)

; 256 spaces — used by --length to right-pad short titles so the
; segment occupies a constant width in strip (other asmites stay put
; as the focused window changes).
pad_spaces:      times 256 db ' '

section .bss

envp:                resq 1
display_num:         resq 1
max_len:             resq 1                ; max display chars

x11_fd:              resq 1
sockaddr_buf:        resb 110
xauth_buf:           resb 4096
xauth_data:          resb 16
xauth_len:           resq 1
conn_setup_buf:      resb 16384

tmp_buf:             resb 4096
title_buf:           resb MAX_TITLE
title_len:           resq 1
out_buf:             resb MAX_TITLE * 2

atom_net_wm_name:    resd 1
atom_utf8_string:    resd 1
focused_xid:         resd 1

section .text
global _start

; ═══════════════════════════════════════════════════════════════════════
_start:
    mov rdi, [rsp]                        ; argc
    lea rsi, [rsp + 8]                    ; argv
    mov rax, rdi
    inc rax
    lea rcx, [rsi + rax*8]                ; envp begins after argv[]+NULL
    mov [envp], rcx

    ; Defaults.
    mov qword [max_len], DEFAULT_LEN

    ; Argv parse: only --length N is recognized.
    mov rcx, rdi                          ; argc
    cmp rcx, 1
    jle .args_done
    mov rbx, 1
.arg_loop:
    cmp rbx, rcx
    jge .args_done
    mov rdi, [rsi + rbx*8]
    cmp dword [rdi], '--le'
    jne .arg_next
    cmp dword [rdi+4], 'ngth'
    jne .arg_next
    cmp byte [rdi+8], 0
    jne .arg_next
    inc rbx
    cmp rbx, rcx
    jge .args_done
    mov rdi, [rsi + rbx*8]
    call atoi
    test eax, eax
    jle .arg_next
    cmp eax, 1024
    jle .arg_len_ok
    mov eax, 1024
.arg_len_ok:
    mov [max_len], rax
.arg_next:
    inc rbx
    jmp .arg_loop
.args_done:

    ; DISPLAY=:N → display_num
    call read_display_num
    test rax, rax
    js .die                               ; no DISPLAY → silent exit

    ; Read auth cookie (best effort; may stay all-zero on systems
    ; without a Xauthority — we still send 0-length auth then).
    call read_xauthority

    ; Connect to the X server.
    call x11_connect
    test rax, rax
    js .die

    ; Intern the atoms we need beyond predefined ones. If the InternAtom
    ; round-trips fail, fall back to predefined WM_NAME later.
    lea rdi, [atom_str_net_wm_name]
    mov rsi, atom_str_net_wm_name_len
    call intern_atom_sync
    mov [atom_net_wm_name], eax

    lea rdi, [atom_str_utf8_string]
    mov rsi, atom_str_utf8_string_len
    call intern_atom_sync
    mov [atom_utf8_string], eax

    ; Find the focused window.
    call get_input_focus
    test eax, eax
    jz .die                               ; PointerRoot or None → no title
    cmp eax, 1                            ; PointerRoot constant
    je .die
    mov [focused_xid], eax

    ; Try _NET_WM_NAME (UTF-8 first; modern apps set it).
    mov edi, eax
    mov esi, [atom_net_wm_name]
    mov edx, [atom_utf8_string]
    call get_window_title
    cmp qword [title_len], 0
    jne .have_title

    ; Fallback: WM_NAME / STRING.
    mov edi, [focused_xid]
    mov esi, ATOM_WM_NAME
    mov edx, ATOM_STRING
    call get_window_title

.have_title:
    cmp qword [title_len], 0
    jne .do_emit
    ; No title — emit max_len spaces so the segment occupies its full
    ; reserved width, then exit. Without this the column would collapse
    ; whenever no window is focused.
    xor eax, eax
    call emit_pad
    jmp .die
.do_emit:
    call write_truncated

.die:
    mov rax, SYS_EXIT
    xor edi, edi
    syscall

; rax = number of codepoints already emitted. Writes (max_len - rax)
; spaces (clamped to ≥0, capped at the static pad_spaces buffer).
; Caller-saved registers are clobbered.
emit_pad:
    mov rcx, [max_len]
    sub rcx, rax
    jle .ep_done
    cmp rcx, 256
    jle .ep_have
    mov rcx, 256
.ep_have:
    mov rax, SYS_WRITE
    mov edi, 1
    lea rsi, [pad_spaces]
    mov rdx, rcx
    syscall
.ep_done:
    ret

; ─────────────────────────────────────────────────────────────────────
; rdi = NUL-terminated decimal string. Returns int in eax (0 on bad).
atoi:
    xor eax, eax
.ai_loop:
    movzx ecx, byte [rdi]
    test cl, cl
    jz .ai_done
    cmp cl, '0'
    jb .ai_done
    cmp cl, '9'
    ja .ai_done
    sub cl, '0'
    imul eax, eax, 10
    add eax, ecx
    inc rdi
    jmp .ai_loop
.ai_done:
    ret

; rax = number, rdi = buffer. Returns digit count in rax.
; Builds digits onto a small local stack region, then reverses into
; the output buffer in one pass.
itoa:
    push rbx
    push r12
    push r13
    mov r12, rdi                          ; remember start of output
    sub rsp, 24                           ; up to 20 digits for u64 + slack
    lea r13, [rsp + 24]                   ; one past digit buffer end
    mov rbx, 10
    test rax, rax
    jnz .it_loop
    dec r13
    mov byte [r13], '0'
    jmp .it_emit
.it_loop:
    xor edx, edx
    div rbx
    add dl, '0'
    dec r13
    mov [r13], dl
    test rax, rax
    jnz .it_loop
.it_emit:
    lea rcx, [rsp + 24]
    sub rcx, r13                          ; digit count
    mov rsi, r13
    mov rdi, r12
    mov r13, rcx
.it_cp:
    test r13, r13
    jz .it_done
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec r13
    jmp .it_cp
.it_done:
    add rsp, 24
    mov rax, rcx                          ; return digit count
    pop r13
    pop r12
    pop rbx
    ret

; rdi = NUL-terminated key (e.g. "DISPLAY"). Returns ptr to value
; (just past '=') in rax, or 0 if not found.
find_envp_var:
    push rbx
    push r12
    mov r12, rdi
    mov rbx, [envp]
.fev_loop:
    mov rax, [rbx]
    test rax, rax
    jz .fev_no
    ; Compare key against env var prefix up to '='.
    mov rdi, r12
    mov rsi, rax
.fev_cmp:
    mov dl, [rdi]
    test dl, dl
    jz .fev_check_eq
    cmp dl, [rsi]
    jne .fev_next
    inc rdi
    inc rsi
    jmp .fev_cmp
.fev_check_eq:
    cmp byte [rsi], '='
    jne .fev_next
    lea rax, [rsi + 1]
    pop r12
    pop rbx
    ret
.fev_next:
    add rbx, 8
    jmp .fev_loop
.fev_no:
    xor eax, eax
    pop r12
    pop rbx
    ret

; Find DISPLAY=, parse :N, store in display_num.
; Returns 0 in rax on success, -1 on missing/invalid.
read_display_num:
    lea rdi, [.rdn_disp]
    call find_envp_var
    test rax, rax
    jz .rdn_fail
    ; rax → "...:N..." Skip until ':' then parse digits.
.rdn_find_colon:
    mov dl, [rax]
    test dl, dl
    jz .rdn_fail
    cmp dl, ':'
    je .rdn_have_colon
    inc rax
    jmp .rdn_find_colon
.rdn_have_colon:
    inc rax
    mov rdi, rax
    call atoi
    mov [display_num], rax
    xor eax, eax
    ret
.rdn_fail:
    mov rax, -1
    ret
.rdn_disp: db "DISPLAY", 0

; Read xauth cookie for the current display. Best-effort: silently
; leaves xauth_len = 0 if the file is absent or no entry matches.
read_xauthority:
    push rbx
    push r12
    push r13
    mov qword [xauth_len], 0

    ; Prefer $XAUTHORITY, fall back to $HOME/.Xauthority.
    lea rdi, [.rxa_xauth]
    call find_envp_var
    test rax, rax
    jnz .rxa_open_path_in_rax
    lea rdi, [.rxa_home]
    call find_envp_var
    test rax, rax
    jz .rxa_done
    mov rsi, rax
    lea rdi, [tmp_buf]
.rxa_cp_home:
    mov al, [rsi]
    test al, al
    jz .rxa_append
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .rxa_cp_home
.rxa_append:
    mov dword [rdi], '/.Xa'
    mov dword [rdi+4], 'utho'
    mov dword [rdi+8], 'rity'
    mov byte [rdi+12], 0
    lea rax, [tmp_buf]
.rxa_open_path_in_rax:
    mov rdi, rax
    mov rax, SYS_OPEN
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js .rxa_done
    mov rbx, rax
    mov rax, SYS_READ
    mov rdi, rbx
    lea rsi, [xauth_buf]
    mov rdx, 4096
    syscall
    mov r12, rax
    mov rax, SYS_CLOSE
    mov rdi, rbx
    syscall
    test r12, r12
    jle .rxa_done
    lea rsi, [xauth_buf]
    lea rdi, [xauth_buf]
    add rdi, r12
.rxa_parse:
    cmp rsi, rdi
    jge .rxa_done
    add rsi, 2                            ; family
    movzx eax, byte [rsi]
    shl eax, 8
    movzx ecx, byte [rsi+1]
    or eax, ecx
    add rsi, 2
    add rsi, rax                          ; address blob
    movzx eax, byte [rsi]
    shl eax, 8
    movzx ecx, byte [rsi+1]
    or eax, ecx
    add rsi, 2
    add rsi, rax                          ; display number string
    movzx eax, byte [rsi]
    shl eax, 8
    movzx ecx, byte [rsi+1]
    or eax, ecx
    add rsi, 2
    mov rbx, rax
    add rsi, rbx                          ; auth name
    movzx eax, byte [rsi]
    shl eax, 8
    movzx ecx, byte [rsi+1]
    or eax, ecx
    add rsi, 2
    cmp eax, 16
    jne .rxa_skip_data
    lea rdi, [xauth_data]
    mov ecx, 16
.rxa_cp_cookie:
    mov bl, [rsi]
    mov [rdi], bl
    inc rsi
    inc rdi
    dec ecx
    jnz .rxa_cp_cookie
    mov qword [xauth_len], 16
    jmp .rxa_done
.rxa_skip_data:
    add rsi, rax
    jmp .rxa_parse
.rxa_done:
    pop r13
    pop r12
    pop rbx
    ret
.rxa_xauth: db "XAUTHORITY", 0
.rxa_home:  db "HOME", 0

; ─────────────────────────────────────────────────────────────────────
; Connect to X via Unix socket and exchange the setup handshake.
; Returns 0 in rax on success, -1 on failure.
x11_connect:
    push rbx
    push r12
    mov rax, SYS_SOCKET
    mov rdi, AF_UNIX
    mov rsi, SOCK_STREAM
    xor edx, edx
    syscall
    test rax, rax
    js .xc_fail
    mov [x11_fd], rax
    mov rbx, rax

    lea rdi, [sockaddr_buf]
    mov word [rdi], AF_UNIX
    add rdi, 2
    lea rsi, [x11_sock_pre]
.xc_cp_path:
    mov al, [rsi]
    test al, al
    jz .xc_cp_num
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .xc_cp_path
.xc_cp_num:
    mov rax, [display_num]
    push rdi
    call itoa
    pop rdi
    add rdi, rax
    mov byte [rdi], 0

    mov rax, SYS_CONNECT
    mov rdi, rbx
    lea rsi, [sockaddr_buf]
    mov rdx, 110
    syscall
    test rax, rax
    js .xc_fail

    ; Build connection-setup request.
    lea rdi, [tmp_buf]
    mov byte [rdi], 0x6C                  ; little-endian
    mov byte [rdi+1], 0
    mov word [rdi+2], 11
    mov word [rdi+4], 0
    mov word [rdi+6], auth_name_len
    movzx eax, word [xauth_len]
    mov word [rdi+8], ax
    mov word [rdi+10], 0
    lea rsi, [auth_name]
    lea rdi, [tmp_buf + 12]
    mov ecx, auth_name_len
.xc_cp_name:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jnz .xc_cp_name
    mov ecx, auth_name_len
    and ecx, 3
    jz .xc_data
    mov edx, 4
    sub edx, ecx
.xc_pad:
    mov byte [rdi], 0
    inc rdi
    dec edx
    jnz .xc_pad
.xc_data:
    movzx ecx, word [xauth_len]
    test ecx, ecx
    jz .xc_send
    lea rsi, [xauth_data]
.xc_cp_cookie:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jnz .xc_cp_cookie
.xc_send:
    mov rdx, rdi
    lea rsi, [tmp_buf]
    sub rdx, rsi
    mov rax, SYS_WRITE
    mov rdi, [x11_fd]
    syscall

    ; Read connection setup reply.
    xor r12, r12
.xc_read:
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [conn_setup_buf]
    add rsi, r12
    mov rdx, 16384
    sub rdx, r12
    jle .xc_read_done
    syscall
    test rax, rax
    jle .xc_fail
    add r12, rax
    cmp r12, 8
    jl .xc_read
    movzx eax, word [conn_setup_buf + 6]
    shl eax, 2
    add eax, 8
    cmp r12d, eax
    jl .xc_read
.xc_read_done:
    cmp byte [conn_setup_buf], 1
    jne .xc_fail
    xor eax, eax
    pop r12
    pop rbx
    ret
.xc_fail:
    mov rax, -1
    pop r12
    pop rbx
    ret

; ─────────────────────────────────────────────────────────────────────
; rdi = ptr to atom name, rsi = length. Returns atom id in eax, or 0
; on failure / unknown.
intern_atom_sync:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_INTERN_ATOM
    mov byte [rdi+1], 0                   ; only-if-exists = 0
    mov rax, r13
    add rax, 3
    shr rax, 2
    add rax, 2
    mov word [rdi+2], ax                  ; request length in words
    mov word [rdi+4], r13w                ; name length
    mov word [rdi+6], 0
    lea rdi, [tmp_buf + 8]
    mov rsi, r12
    mov rcx, r13
.ias_cp:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
    jnz .ias_cp
    mov rcx, r13
    and rcx, 3
    jz .ias_send
    mov edx, 4
    sub edx, ecx
.ias_pad:
    mov byte [rdi], 0
    inc rdi
    dec edx
    jnz .ias_pad
.ias_send:
    mov rax, r13
    add rax, 3
    and rax, ~3
    add rax, 8
    mov rdx, rax
    lea rsi, [tmp_buf]
    mov rax, SYS_WRITE
    mov rdi, [x11_fd]
    syscall

    call read_reply
    test rax, rax
    js .ias_fail
    mov eax, [tmp_buf + 8]                ; atom in reply byte 8..11
    pop r13
    pop r12
    pop rbx
    ret
.ias_fail:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

; GetInputFocus: returns focused window XID in eax, or 0/1 on
; PointerRoot/None.
get_input_focus:
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_GET_INPUT_FOCUS
    mov byte [rdi+1], 0
    mov word [rdi+2], 1                   ; length = 1 word = 4 bytes
    lea rsi, [tmp_buf]
    mov rdx, 4
    mov rax, SYS_WRITE
    mov rdi, [x11_fd]
    syscall

    call read_reply
    test rax, rax
    js .gif_fail
    mov eax, [tmp_buf + 8]                ; focus window at byte 8
    ret
.gif_fail:
    xor eax, eax
    ret

; edi = window XID, esi = property atom, edx = type atom.
; Reads up to MAX_TITLE bytes. Stores result in title_buf, length in
; title_len.
get_window_title:
    push rbx
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov qword [title_len], 0

    lea rdi, [tmp_buf]
    mov byte [rdi], X11_GET_PROPERTY
    mov byte [rdi+1], 0                   ; delete = 0
    mov word [rdi+2], 6                   ; length = 6 words
    mov [rdi+4], r12d                     ; window
    mov [rdi+8], r13d                     ; property
    mov [rdi+12], r14d                    ; type
    mov dword [rdi+16], 0                 ; long-offset = 0
    mov dword [rdi+20], MAX_TITLE / 4     ; long-length in 32-bit units
    lea rsi, [tmp_buf]
    mov rdx, 24
    mov rax, SYS_WRITE
    mov rdi, [x11_fd]
    syscall

    call read_reply
    test rax, rax
    js .gwt_done
    ; reply byte 16 = value-length in <format> units. For STRING/UTF8
    ; format=8 so value-length is the byte count directly.
    mov ecx, [tmp_buf + 16]               ; value-length
    test ecx, ecx
    jz .gwt_done
    cmp ecx, MAX_TITLE
    jbe .gwt_len_ok
    mov ecx, MAX_TITLE
.gwt_len_ok:
    mov [title_len], rcx
    ; Bytes start at offset 32 of the reply (which lives at tmp_buf).
    lea rsi, [tmp_buf + 32]
    lea rdi, [title_buf]
.gwt_cp:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jnz .gwt_cp
.gwt_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Read one X11 reply / error into tmp_buf. Returns 0 on success, -1
; on error reply or read failure. Skips events until a reply (1) or
; error (0) arrives.
read_reply:
    push rbx
    push r12
.rr_read_loop:
    xor r12, r12
.rr_hdr:
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [tmp_buf]
    add rsi, r12
    mov rdx, 32
    sub rdx, r12
    jle .rr_have_hdr
    syscall
    test rax, rax
    jle .rr_fail
    add r12, rax
    cmp r12, 32
    jl .rr_hdr
.rr_have_hdr:
    mov al, [tmp_buf]
    cmp al, 0
    je .rr_fail                           ; X error
    cmp al, 1
    jne .rr_event_skip                    ; event — drop and try again
    ; Reply: bytes 4..7 = additional length in 4-byte units.
    mov eax, [tmp_buf + 4]
    shl eax, 2
    test eax, eax
    jz .rr_ok
    add eax, 32
    cmp eax, 4096
    jbe .rr_eax_ok
    mov eax, 4096
.rr_eax_ok:
    mov r12d, 32
.rr_body:
    cmp r12d, eax
    jge .rr_ok
    mov rdx, rax
    sub rdx, r12
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [tmp_buf]
    add rsi, r12
    syscall
    test rax, rax
    jle .rr_fail
    add r12d, eax
    jmp .rr_body
.rr_ok:
    xor eax, eax
    pop r12
    pop rbx
    ret
.rr_event_skip:
    ; Event consumed (32 bytes already read); loop to try next packet.
    jmp .rr_read_loop
.rr_fail:
    mov rax, -1
    pop r12
    pop rbx
    ret

; ─────────────────────────────────────────────────────────────────────
; Print the buffered title, mid-string-truncated if its display width
; exceeds [max_len]. Newlines, tabs, and stray control bytes are
; replaced with spaces so the bar layout stays single-line.
;
; Display-width metric: count UTF-8 codepoints (bytes whose top two
; bits are NOT 10), not raw bytes — so a "äpple" with 5 chars is
; treated as length 5, not 6.
write_truncated:
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; Sanitize title_buf in place: tabs/newlines/<0x20 → space.
    mov rdi, title_buf
    mov rcx, [title_len]
.wt_san:
    test rcx, rcx
    jz .wt_san_done
    movzx eax, byte [rdi]
    cmp al, 0x20
    jae .wt_san_next
    mov byte [rdi], 0x20
.wt_san_next:
    inc rdi
    dec rcx
    jmp .wt_san
.wt_san_done:

    ; Compute display width (UTF-8 codepoint count).
    mov r12, [title_len]                  ; byte count
    mov rsi, title_buf
    xor r13, r13                          ; codepoint count
    xor rcx, rcx
.wt_count:
    cmp rcx, r12
    jge .wt_count_done
    movzx eax, byte [rsi + rcx]
    and al, 0xC0
    cmp al, 0x80
    je .wt_count_skip
    inc r13
.wt_count_skip:
    inc rcx
    jmp .wt_count
.wt_count_done:
    ; r13 = codepoint count.

    mov r14, [max_len]
    cmp r13, r14
    jbe .wt_emit_full

    ; Need to truncate. Two strategies:
    ;   max_len < 8  → simple right-truncation with trailing "…"
    ;   else         → mid-truncate: keep (max_len-1)/2 prefix codepoints,
    ;                  insert "…", then keep (max_len-1)/2 suffix codepoints.
    cmp r14, 8
    jl .wt_right_truncate

    ; Mid-truncate. left_keep = (max_len - 1 + 1) / 2 ; right_keep = (max_len - 1) / 2
    mov rax, r14
    dec rax
    mov rbx, rax
    inc rbx
    shr rbx, 1                            ; left_keep
    shr rax, 1                            ; right_keep
    mov r15, rax                          ; stash right_keep — copy_codepoints clobbers rax

    ; Copy first `left_keep` codepoints.
    mov rsi, title_buf
    mov rdi, out_buf
    mov rcx, rbx                          ; left_keep
    call copy_codepoints                  ; advances rsi, rdi
    ; Append "…" (3 bytes UTF-8).
    mov al, [ellipsis]
    mov [rdi], al
    mov al, [ellipsis + 1]
    mov [rdi + 1], al
    mov al, [ellipsis + 2]
    mov [rdi + 2], al
    add rdi, 3
    ; Skip to the start of the suffix: skip (total_cp - right_keep) codepoints.
    mov rsi, title_buf
    mov rcx, r13
    sub rcx, r15                          ; codepoints to skip
    call skip_codepoints                  ; advances rsi
    mov rcx, r15                          ; right_keep
    call copy_codepoints
    jmp .wt_emit_buf

.wt_right_truncate:
    ; Keep (max_len - 1) codepoints + "…"
    mov rsi, title_buf
    mov rdi, out_buf
    mov rcx, r14
    dec rcx
    test rcx, rcx
    jz .wt_just_ellipsis
    call copy_codepoints
.wt_just_ellipsis:
    mov al, [ellipsis]
    mov [rdi], al
    mov al, [ellipsis + 1]
    mov [rdi + 1], al
    mov al, [ellipsis + 2]
    mov [rdi + 2], al
    add rdi, 3
.wt_emit_buf:
    mov rdx, rdi
    lea rsi, [out_buf]
    sub rdx, rsi
    mov rax, SYS_WRITE
    mov rdi, 1
    syscall
    ; Truncated emits fill exactly max_len codepoints already; no
    ; padding required.
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.wt_emit_full:
    mov rax, SYS_WRITE
    mov rdi, 1
    lea rsi, [title_buf]
    mov rdx, [title_len]
    syscall
    ; Pad to max_len codepoints with trailing spaces (r13 holds the
    ; codepoint count for the title we just emitted).
    mov rax, r13
    call emit_pad
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Copy `rcx` UTF-8 codepoints from rsi to rdi, advancing both. UTF-8
; continuation bytes (10xxxxxx) are copied alongside their leading byte
; without consuming an extra codepoint slot.
copy_codepoints:
    test rcx, rcx
    jz .cc_done
.cc_lead:
    mov al, [rsi]
    test al, al
    jz .cc_done
    mov [rdi], al
    inc rsi
    inc rdi
    dec rcx
.cc_cont:
    mov al, [rsi]
    test al, al
    jz .cc_done
    mov dl, al
    and dl, 0xC0
    cmp dl, 0x80
    jne .cc_check
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .cc_cont
.cc_check:
    test rcx, rcx
    jnz .cc_lead
.cc_done:
    ret

; Skip `rcx` UTF-8 codepoints starting at rsi, advancing rsi.
skip_codepoints:
    test rcx, rcx
    jz .sc_done
.sc_lead:
    mov al, [rsi]
    test al, al
    jz .sc_done
    inc rsi
    dec rcx
.sc_cont:
    mov al, [rsi]
    test al, al
    jz .sc_done
    mov dl, al
    and dl, 0xC0
    cmp dl, 0x80
    jne .sc_check
    inc rsi
    jmp .sc_cont
.sc_check:
    test rcx, rcx
    jnz .sc_lead
.sc_done:
    ret
