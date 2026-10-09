
; RetroKeyTest v1.0
; 16-bit DOS .COM program
; IBM PC/AT compatible, 286+
; NASM: nasm -f bin KEYTEST.ASM -o KEYTEST.COM
;
; Runs in real DOS, not Windows PowerShell.
; Captures raw IRQ1 keyboard scan codes (set 1).
; ESC exits when pressed and released.

bits 16
org 100h

%define SCREEN_SEG 0B800h
%define KEY_COUNT 128

start:
    push cs
    pop ds

    ; Save original INT 09h vector
    mov ax, 3509h
    int 21h
    mov [old_int09_off], bx
    mov [old_int09_seg], es

    ; Set text mode 03h (80x25 color)
    mov ax, 0003h
    int 10h

    ; Draw interface
    call draw_screen

    ; Install keyboard interrupt handler
    cli
    push ds
    mov dx, keyboard_isr
    mov ax, 2509h
    int 21h
    pop ds
    sti

main_loop:
    ; Atomically retrieve pending event
    cli
    mov al, [event_pending]
    mov byte [event_pending], 0
    sti

    test al, al
    jz .check_exit

    call update_display

.check_exit:
    cmp byte [exit_requested], 1
    jne main_loop

    ; Restore original interrupt vector
    cli
    push ds
    mov dx, [old_int09_off]
    mov ax, [old_int09_seg]
    mov ds, ax
    mov ax, 2509h
    int 21h
    pop ds
    sti

    ; Restore text mode
    mov ax, 0003h
    int 10h

    mov ax, 4C00h
    int 21h

; ---------------------------------------
; IRQ1 keyboard interrupt handler
; ---------------------------------------
keyboard_isr:
    push ax
    push bx
    push cx
    push dx
    push ds

    push cs
    pop ds

    ; Read keyboard scan code
    in al, 60h
    mov bl, al

    ; Acknowledge keyboard controller
    in al, 61h
    mov ah, al
    or al, 80h
    out 61h, al
    mov al, ah
    out 61h, al

    ; Handle E0 extended prefix
    cmp bl, 0E0h
    je .extended

    ; Ignore E1 prefix (Pause)
    cmp bl, 0E1h
    je .done

    mov al, bl
    and al, 7Fh
    xor ah, ah
    mov bx, ax

    ; Record key as tested
    mov byte [tested_keys + bx], 1

    ; Count unique tested keys
    cmp byte [counted_keys + bx], 1
    je .already_counted

    mov byte [counted_keys + bx], 1
    inc word [tested_count]

.already_counted:
    mov al, [extended_flag]
    mov [last_extended], al
    mov byte [extended_flag], 0

    mov al, [last_scan]
    ; Store current raw code instead
    ; (re-read is avoided by reconstructing
    ;  make/break from the saved value)
    mov al, bl
    mov [last_scan], al

    mov byte [event_pending], 1

    ; ESC make code = 01h
    cmp bl, 1
    jne .done
    mov byte [exit_requested], 1
    jmp .done

.extended:
    mov byte [extended_flag], 1

.done:
    ; Send EOI to master PIC
    mov al, 20h
    out 20h, al

    pop ds
    pop dx
    pop cx
    pop bx
    pop ax
    iret

; ---------------------------------------
; Draw initial screen
; ---------------------------------------
draw_screen:
    push ax
    push bx
    push cx
    push dx
    push si

    mov si, title_text
    mov dh, 1
    mov dl, 2
    call print_at

    mov si, subtitle_text
    mov dh, 3
    mov dl, 2
    call print_at

    mov si, help_text
    mov dh, 5
    mov dl, 2
    call print_at

    mov si, scan_label
    mov dh, 8
    mov dl, 2
    call print_at

    mov si, count_label
    mov dh, 10
    mov dl, 2
    call print_at

    mov si, exit_text
    mov dh, 22
    mov dl, 2
    call print_at

    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ---------------------------------------
; Print zero-terminated string
; DS:SI = string, DH=row, DL=column
; ---------------------------------------
print_at:
    push ax
    push bx
    push dx

    mov ah, 02h
    mov bh, 0
    int 10h

.next:
    lodsb
    test al, al
    jz .finished

    mov ah, 0Eh
    mov bh, 0
    mov bl, 0Ah
    int 10h
    jmp .next

.finished:
    pop dx
    pop bx
    pop ax
    ret

; ---------------------------------------
; Update diagnostic display
; ---------------------------------------
update_display:
    push ax
    push bx
    push dx

    ; Position cursor after "Scan code:"
    mov ah, 02h
    mov bh, 0
    mov dh, 8
    mov dl, 15
    int 10h

    mov al, [last_scan]
    call print_hex_byte

    ; Position cursor after "Keys tested:"
    mov ah, 02h
    mov bh, 0
    mov dh, 10
    mov dl, 16
    int 10h

    mov ax, [tested_count]
    call print_decimal

    pop dx
    pop bx
    pop ax
    ret

; ---------------------------------------
; Print AL as two hexadecimal digits
; ---------------------------------------
print_hex_byte:
    push ax
    push bx

    mov bl, al
    shr al, 4
    call print_hex_nibble

    mov al, bl
    and al, 0Fh
    call print_hex_nibble

    pop bx
    pop ax
    ret

print_hex_nibble:
    and al, 0Fh
    cmp al, 9
    jbe .digit
    add al, 7

.digit:
    add al, '0'
    mov ah, 0Eh
    mov bh, 0
    int 10h
    ret

; ---------------------------------------
; Print unsigned AX in decimal
; ---------------------------------------
print_decimal:
    push ax
    push bx
    push cx
    push dx

    xor cx, cx
    mov bx, 10

.divide:
    xor dx, dx
    div bx
    push dx
    inc cx
    test ax, ax
    jnz .divide

.print:
    pop ax
    add al, '0'
    mov ah, 0Eh
    mov bh, 0
    int 10h
    loop .print

    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ---------------------------------------
; Data
; ---------------------------------------
title_text:
    db 'RETRO KEYBOARD TEST v1.0', 0

subtitle_text:
    db 'IBM PC/AT - 286 and newer', 0

help_text:
    db 'Press keys to test keyboard scan codes.', 0

scan_label:
    db 'Scan code:', 0

count_label:
    db 'Keys tested:', 0

exit_text:
    db 'Press ESC to exit.', 0

old_int09_off dw 0
old_int09_seg dw 0

last_scan db 0
last_extended db 0
extended_flag db 0
event_pending db 0
exit_requested db 0

tested_count dw 0

tested_keys:
    times KEY_COUNT db 0

counted_keys:
    times KEY_COUNT db 0
