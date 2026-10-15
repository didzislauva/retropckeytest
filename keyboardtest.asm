; RetroKeyTest v1.1 - one NASM source, three build modes
; DOS program:       nasm -f bin keyboardtest.asm -o KEYTEST.COM
; Boot sector:       nasm -f bin -DBOOT_SECTOR -DSTAGE_SECTORS=6 keyboardtest.asm -o bootsector.bin
; Booted tester:     nasm -f bin -DBOOT_STAGE keyboardtest.asm -o stage2.bin
; Use build-keyboardtest-boot.sh to calculate STAGE_SECTORS and make the image.
; IBM PC/AT compatible, 286+, color text display.
;
; BOOT_SECTOR runs at 0x7C00 and loads BOOT_STAGE at 0x8000.
; The default build is a DOS .COM program loaded by DOS at offset 0x100.
;
bits 16

%ifdef BOOT_SECTOR
; Sector 0 of the DOS-free keyboard test floppy.
; The BIOS copies this 512-byte sector to physical address 0x7C00 and runs it.
; This program then copies the keyboard tester from the next disk sectors to
; physical address 0x8000 and jumps there. No DOS or filesystem is involved.

; Tell NASM where the BIOS will have placed this code in memory.
; ORG does not load the sector; the BIOS does that before execution begins.
org 7C00h

%ifndef STAGE_SECTORS
    %error STAGE_SECTORS must be supplied by the build script
%endif
%if STAGE_SECTORS < 1 || STAGE_SECTORS > 17
    %error Stage 2 must fit in sectors 2 through 18 of track 0
%endif

start:
    ; Set up segment registers and a stack. A real-mode address is segment:offset;
    ; 0000:7C00 means physical address 0x7C00. The stack grows downward from here.
    cli
    xor ax, ax
    mov ss, ax
    mov sp, 7C00h
    mov ds, ax
    ; ES:BX will be the destination of the BIOS disk read: 0000:8000.
    mov es, ax
    cld
    sti

    ; BIOS passes the number of the boot drive in DL. Save it for INT 13h.
    mov [boot_drive], dl
    mov byte [retries], 3

.read_stage:
    ; Reset the floppy before each read attempt: INT 13h, AH=00h.
    xor ah, ah
    mov dl, [boot_drive]
    int 13h

    ; Read the keyboard tester with BIOS INT 13h, function AH=02h.
    ; AL=STAGE_SECTORS is the number of 512-byte sectors to read (currently 6),
    ; so AX=0206h in the current image. The build script calculates this count.
    mov ax, 0200h + STAGE_SECTORS
    ; BIOS writes the data to ES:BX = 0000:8000 (physical address 0x8000).
    mov bx, 8000h
    ; CH=0: cylinder/track 0. CL=2: start at BIOS sector 2.
    ; BIOS numbers sectors from 1, so sector 2 is image sector 1, immediately
    ; after the boot sector. The stage fits in sectors 2 through 18 on head 0.
    xor ch, ch
    mov cl, 2
    ; DH=0: head 0. DL: the floppy drive from which BIOS booted us.
    xor dh, dh
    mov dl, [boot_drive]
    ; Carry flag clear means the read succeeded; set means it failed.
    int 13h
    jnc .start_stage

    dec byte [retries]
    jnz .read_stage

    mov si, disk_error
.print:
    lodsb
    test al, al
    jz .stop
    mov ah, 0Eh
    xor bx, bx
    int 10h
    jmp .print
.stop:
    hlt
    jmp .stop

.start_stage:
    ; The tester is now in RAM. Begin executing its first instruction.
    jmp 0000h:8000h

boot_drive db 0
retries db 0
disk_error db 'Keyboard test: floppy read failed.', 0

; Pad to byte 510, then write the boot signature bytes 55 AA at bytes 510-511.
times 510 - ($ - $$) db 0
dw 0AA55h

%else ; DOS .COM or booted tester
bits 16
%ifdef BOOT_STAGE
org 8000h
%else
org 100h
%endif

%define SCREEN_SEG 0B800h
%define KEY_COUNT 256

; KEY scan, extended, row, column, width, label
%macro KEY 6
    db %1, %2, %3, %4, %5
%%label: db %6
    times 6 - ($ - %%label) db ' '
%endmacro

start:
    cld
    push cs
    pop ds

    ; Save original INT 09h vector
%ifdef BOOT_STAGE
    xor ax, ax
    mov es, ax
    mov bx, [es:24h]
    mov [old_int09_off], bx
    mov bx, [es:26h]
    mov [old_int09_seg], bx
%else
    mov ax, 3509h
    int 21h
    mov [old_int09_off], bx
    mov [old_int09_seg], es
%endif

    ; Set text mode 03h (80x25 color)
    mov ax, 0003h
    int 10h

    ; Draw interface
    call draw_screen

    ; Install keyboard interrupt handler
    cli
%ifdef BOOT_STAGE
    xor ax, ax
    mov es, ax
    mov word [es:24h], keyboard_isr
    mov [es:26h], cs
%else
    push ds
    mov dx, keyboard_isr
    mov ax, 2509h
    int 21h
    pop ds
%endif
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
%ifdef BOOT_STAGE
    xor ax, ax
    mov es, ax
    mov bx, [old_int09_off]
    mov [es:24h], bx
    mov bx, [old_int09_seg]
    mov [es:26h], bx
%else
    push ds
    mov dx, [old_int09_off]
    mov ax, [old_int09_seg]
    mov ds, ax
    mov ax, 2509h
    int 21h
    pop ds
%endif
    sti

    ; Restore text mode
    mov ax, 0003h
    int 10h

%ifdef BOOT_STAGE
    mov si, finished_text
    mov dh, 11
    mov dl, 8
    call print_at
.halt:
    hlt
    jmp .halt
%else
    mov ax, 4C00h
    int 21h
%endif

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

    ; Pause sends an E1 sequence with no ordinary break code.
    cmp byte [pause_bytes], 0
    je .check_prefix
    dec byte [pause_bytes]
    jmp .done

.check_prefix:
    ; Handle E0 extended prefix
    cmp bl, 0E0h
    je .extended

    ; Treat the entire E1 Pause sequence as one key.
    cmp bl, 0E1h
    je .pause

    mov dl, bl                    ; Preserve the raw make/break code
    and bl, 7Fh
    xor bh, bh

    mov al, [extended_flag]
    mov [last_extended], al
    mov byte [extended_flag], 0
    test al, al
    jz .normal_key
    ; Print Screen includes synthetic E0 Shift codes.
    cmp bl, 2Ah
    je .done
    cmp bl, 36h
    je .done
    add bx, 128                  ; E0 keys have their own state slots
.normal_key:
    test dl, 80h
    jnz .key_up

    mov byte [pressed_keys + bx], 1
    cmp byte [tested_keys + bx], 1
    je .record_event
    mov byte [tested_keys + bx], 1
    inc word [tested_count]
    jmp .record_event

.key_up:
    mov byte [pressed_keys + bx], 0

.record_event:
    mov [last_scan], dl
    mov byte [event_pending], 1

    ; ESC break code = 81h (not an E0 key)
    cmp dl, 81h
    jne .done
    cmp byte [last_extended], 0
    jne .done
    mov byte [exit_requested], 1
    jmp .done

.extended:
    mov byte [extended_flag], 1
    jmp .done

.pause:
    mov byte [pause_bytes], 5
    mov byte [extended_flag], 0
    mov byte [last_extended], 2
    mov byte [last_scan], 0E1h
    mov byte [event_pending], 1
    cmp byte [tested_keys + 255], 0
    jne .done
    mov byte [tested_keys + 255], 1
    inc word [tested_count]

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
    mov dh, 0
    mov dl, 2
    call print_at

    mov si, subtitle_text
    mov dh, 1
    mov dl, 2
    call print_at

    mov si, scan_label
    mov dh, 17
    mov dl, 2
    call print_at

    mov si, count_label
    mov dh, 19
    mov dl, 2
    call print_at

    mov si, legend_text
    mov dh, 21
    mov dl, 2
    call print_at

    mov si, exit_text
    mov dh, 23
    mov dl, 2
    call print_at

    call draw_keys

    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; Repaint key caps from their current states. Each table entry is 11 bytes:
; scan code, E0 flag, row, column, width, six label characters.
draw_keys:
    push ax
    push si
    mov si, key_table
.next:
    cmp byte [si], 0FFh
    je .done
    call draw_key
    add si, 11
    jmp .next
.done:
    pop si
    pop ax
    ret

draw_key:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    mov bl, [si]
    xor bh, bh
    cmp byte [si + 1], 0
    je .state
    add bx, 128
.state:
    mov ah, 17h                 ; Blue: untested
    cmp byte [tested_keys + bx], 0
    je .position
    mov ah, 2Fh                 ; Green: tested
    cmp byte [pressed_keys + bx], 0
    je .position
    mov ah, 70h                 ; White: currently held

.position:
    mov dl, ah                  ; Keep attribute while calculating position
    mov al, [si + 2]
    mov cl, 160
    mul cl
    mov di, ax
    mov al, [si + 3]
    xor ah, ah
    shl ax, 1
    add di, ax

    mov ax, SCREEN_SEG
    mov es, ax
    mov cl, [si + 4]
    xor ch, ch
    add si, 5
    mov bx, 6
.cell:
    test bx, bx
    jz .blank
    lodsb
    dec bx
    jmp .write
.blank:
    mov al, ' '
.write:
    mov ah, dl
    stosw
    loop .cell

    pop es
    pop di
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
    push si

    ; Show the scan code without the release bit.
    mov ah, 02h
    mov bh, 0
    mov dh, 17
    mov dl, 8
    int 10h

    cmp byte [last_extended], 2
    jne .ordinary_code
    mov si, no_prefix_text      ; Pause has an E1 sequence, not one scan code
    mov dh, 17
    mov dl, 8
    call print_at
    jmp .raw_code
.ordinary_code:
    mov al, [last_scan]
    and al, 7Fh
    call print_hex_byte

.raw_code:
    mov ah, 02h
    mov bh, 0
    mov dh, 17
    mov dl, 18
    int 10h
    mov al, [last_scan]
    call print_hex_byte

    mov si, pause_text
    cmp byte [last_extended], 2
    je .direction
    mov si, up_text
    test byte [last_scan], 80h
    jnz .direction
    mov si, down_text
.direction:
    mov dh, 17
    mov dl, 23
    call print_at

    mov si, no_prefix_text
    cmp byte [last_extended], 0
    je .prefix
    mov si, e0_prefix_text
    cmp byte [last_extended], 1
    je .prefix
    mov si, e1_prefix_text
.prefix:
    mov dh, 17
    mov dl, 38
    call print_at

    ; Position cursor after "Unique keys:"
    mov ah, 02h
    mov bh, 0
    mov dh, 19
    mov dl, 15
    int 10h

    mov ax, [tested_count]
    call print_decimal

    call draw_keys

    pop si
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
    db 'RETRO KEYBOARD TEST v1.1', 0

subtitle_text:
    db 'IBM PC/AT - press a key to mark it', 0

scan_label:
    db 'Scan: 00   Raw: 00   DOWN   Prefix: --', 0

count_label:
    db 'Unique keys: 0', 0

legend_text:
    db 'Blue = untested   Green = tested   White = held', 0

exit_text:
%ifdef BOOT_STAGE
    db 'Release Esc to stop the test.', 0
finished_text:
    db 'Test finished. Press Ctrl+Alt+Del to reboot.', 0
%else
    db 'Release Esc to return to DOS.', 0
%endif

up_text: db 'UP  ', 0
down_text: db 'DOWN', 0
pause_text: db 'TAP ', 0
no_prefix_text: db '--', 0
e0_prefix_text: db 'E0', 0
e1_prefix_text: db 'E1', 0

key_table:
    ; Function row
    KEY 01h, 0, 3,  2, 5, 'Esc'
    KEY 3Bh, 0, 3,  9, 4, 'F1'
    KEY 3Ch, 0, 3, 14, 4, 'F2'
    KEY 3Dh, 0, 3, 19, 4, 'F3'
    KEY 3Eh, 0, 3, 24, 4, 'F4'
    KEY 3Fh, 0, 3, 30, 4, 'F5'
    KEY 40h, 0, 3, 35, 4, 'F6'
    KEY 41h, 0, 3, 40, 4, 'F7'
    KEY 42h, 0, 3, 45, 4, 'F8'
    KEY 43h, 0, 3, 51, 4, 'F9'
    KEY 44h, 0, 3, 56, 5, 'F10'
    KEY 57h, 0, 3, 62, 5, 'F11'
    KEY 58h, 0, 3, 68, 5, 'F12'

    ; Number row and navigation block
    KEY 29h, 0, 5,  2, 3, '~'
    KEY 02h, 0, 5,  6, 3, '1'
    KEY 03h, 0, 5, 10, 3, '2'
    KEY 04h, 0, 5, 14, 3, '3'
    KEY 05h, 0, 5, 18, 3, '4'
    KEY 06h, 0, 5, 22, 3, '5'
    KEY 07h, 0, 5, 26, 3, '6'
    KEY 08h, 0, 5, 30, 3, '7'
    KEY 09h, 0, 5, 34, 3, '8'
    KEY 0Ah, 0, 5, 38, 3, '9'
    KEY 0Bh, 0, 5, 42, 3, '0'
    KEY 0Ch, 0, 5, 46, 3, '-'
    KEY 0Dh, 0, 5, 50, 3, '='
    KEY 0Eh, 0, 5, 54, 6, 'Back'
    KEY 52h, 1, 5, 62, 5, 'Ins'
    KEY 47h, 1, 5, 68, 5, 'Home'
    KEY 49h, 1, 5, 74, 5, 'PgUp'

    ; QWERTY row
    KEY 0Fh, 0, 7,  2, 5, 'Tab'
    KEY 10h, 0, 7,  8, 3, 'Q'
    KEY 11h, 0, 7, 12, 3, 'W'
    KEY 12h, 0, 7, 16, 3, 'E'
    KEY 13h, 0, 7, 20, 3, 'R'
    KEY 14h, 0, 7, 24, 3, 'T'
    KEY 15h, 0, 7, 28, 3, 'Y'
    KEY 16h, 0, 7, 32, 3, 'U'
    KEY 17h, 0, 7, 36, 3, 'I'
    KEY 18h, 0, 7, 40, 3, 'O'
    KEY 19h, 0, 7, 44, 3, 'P'
    KEY 1Ah, 0, 7, 48, 3, '['
    KEY 1Bh, 0, 7, 52, 3, ']'
    KEY 2Bh, 0, 7, 56, 4, '\'
    KEY 53h, 1, 7, 62, 5, 'Del'
    KEY 4Fh, 1, 7, 68, 5, 'End'
    KEY 51h, 1, 7, 74, 5, 'PgDn'

    ; Home row and keypad controls
    KEY 3Ah, 0, 9,  2, 6, 'Caps'
    KEY 1Eh, 0, 9,  9, 3, 'A'
    KEY 1Fh, 0, 9, 13, 3, 'S'
    KEY 20h, 0, 9, 17, 3, 'D'
    KEY 21h, 0, 9, 21, 3, 'F'
    KEY 22h, 0, 9, 25, 3, 'G'
    KEY 23h, 0, 9, 29, 3, 'H'
    KEY 24h, 0, 9, 33, 3, 'J'
    KEY 25h, 0, 9, 37, 3, 'K'
    KEY 26h, 0, 9, 41, 3, 'L'
    KEY 27h, 0, 9, 45, 3, ';'
    KEY 28h, 0, 9, 49, 3, "'"
    KEY 1Ch, 0, 9, 53, 7, 'Enter'
    KEY 45h, 0, 9, 62, 5, 'Num'
    KEY 35h, 1, 9, 68, 3, '/'
    KEY 37h, 0, 9, 72, 3, '*'
    KEY 4Ah, 0, 9, 76, 3, '-'

    ; Shift row and keypad 7-9
    KEY 2Ah, 0, 11,  2, 7, 'Shift'
    KEY 2Ch, 0, 11, 10, 3, 'Z'
    KEY 2Dh, 0, 11, 14, 3, 'X'
    KEY 2Eh, 0, 11, 18, 3, 'C'
    KEY 2Fh, 0, 11, 22, 3, 'V'
    KEY 30h, 0, 11, 26, 3, 'B'
    KEY 31h, 0, 11, 30, 3, 'N'
    KEY 32h, 0, 11, 34, 3, 'M'
    KEY 33h, 0, 11, 38, 3, ','
    KEY 34h, 0, 11, 42, 3, '.'
    KEY 35h, 0, 11, 46, 3, '/'
    KEY 36h, 0, 11, 50, 7, 'Shift'
    KEY 47h, 0, 11, 62, 3, '7'
    KEY 48h, 0, 11, 66, 3, '8'
    KEY 49h, 0, 11, 70, 3, '9'
    KEY 4Eh, 0, 11, 74, 5, '+'

    ; Bottom row and keypad 4-6
    KEY 1Dh, 0, 13,  2, 6, 'Ctrl'
    KEY 38h, 0, 13,  9, 5, 'Alt'
    KEY 39h, 0, 13, 15, 28, 'Space'
    KEY 38h, 1, 13, 44, 5, 'AltGr'
    KEY 1Dh, 1, 13, 50, 6, 'Ctrl'
    KEY 4Bh, 0, 13, 62, 3, '4'
    KEY 4Ch, 0, 13, 66, 3, '5'
    KEY 4Dh, 0, 13, 70, 3, '6'

    ; Print/lock keys, arrows, and keypad 1-3
    KEY 37h, 1, 15,  2, 6, 'PrtSc'
    KEY 46h, 0, 15,  9, 6, 'Scroll'
    KEY 7Fh, 1, 15, 16, 6, 'Pause'
    KEY 48h, 1, 15, 48, 5, 'Up'
    KEY 4Fh, 0, 15, 62, 3, '1'
    KEY 50h, 0, 15, 66, 3, '2'
    KEY 51h, 0, 15, 70, 3, '3'
    KEY 1Ch, 1, 15, 74, 5, 'Enter'

    KEY 4Bh, 1, 16, 42, 5, 'Left'
    KEY 50h, 1, 16, 48, 5, 'Down'
    KEY 4Dh, 1, 16, 54, 5, 'Right'
    KEY 52h, 0, 17, 62, 7, '0'
    KEY 53h, 0, 17, 70, 3, '.'

    db 0FFh

old_int09_off dw 0
old_int09_seg dw 0

last_scan db 0
last_extended db 0
extended_flag db 0
pause_bytes db 0
event_pending db 0
exit_requested db 0

tested_count dw 0

tested_keys: times KEY_COUNT db 0
pressed_keys: times KEY_COUNT db 0

%endif ; BOOT_SECTOR
