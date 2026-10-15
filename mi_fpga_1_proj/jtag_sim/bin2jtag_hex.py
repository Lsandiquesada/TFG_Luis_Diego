#!/usr/bin/env python3
"""
Convierte el bitstream .bin de FABulous (fir_filter_top.bin) al .hex que lee
tb_chip_top_fir.v: una linea por frame, en hexadecimal, con el formato
    {addr[ADDR_W-1:0], FrameData[FRAME_W-1:0]}      (130 digitos hex con 8+512 bits)
que es exactamente el DR de configuracion de jtag_fabric_config.

Reglas tomadas de los archivos generados de tu fabric:

  ConfigFSM.v
    - Todo lo anterior a la palabra 0xFAB0FAB1 se ignora (cabecera).
    - Despues de la sincronizacion: palabra de seleccion + NumberOfRows palabras de datos.
    - Si la palabra de seleccion tiene el bit 20 (desync_flag) en 1 -> fin del bitstream.
    - Primera palabra de datos -> fila NumberOfRows, la siguiente -> NumberOfRows-1, ...,
      la ultima -> fila 1.  (row_select = row_index, que cuenta hacia abajo)
  eFPGA_top.v
    - NumberOfRows = 14, FrameBitsPerRow = 32
    - assign FrameData = {32'h12345678, FrameRegister, 32'h12345678}
        -> fila 0 y fila 15 (bordes) valen 0x12345678; la fila r (1..14) esta en
           FrameData[32*r +: 32] y es la salida de Frame_Data_Reg con Row = r.
  Frame_Select.v + eFPGA_top.v
    - Columna = palabra_seleccion[31:27]; frame (one-hot) = palabra_seleccion[19:0]
    - FrameStrobe[col*MaxFramesPerCol + frame]  ->  addr = col*20 + frame

Uso:
    python3 bin2jtag_hex.py fir_filter_top.bin fir_filter_top_jtag.hex
    python3 bin2jtag_hex.py --selftest
"""
import argparse
import random
import struct
import sys

SYNC = 0xFAB0FAB1
BORDER_WORD = 0x12345678
DESYNC_BIT = 20


def read_words(path):
    data = open(path, "rb").read()
    if len(data) % 4:
        sys.exit(f"ERROR: el tamano de {path} ({len(data)} bytes) no es multiplo de 4")
    return list(struct.unpack(">%dI" % (len(data) // 4), data))


def parse_frames(words, n_rows, bits, frames_per_col):
    """Devuelve [(addr, FrameData_int)] en el orden del archivo."""
    if SYNC not in words:
        sys.exit("ERROR: no se encontro la palabra de sincronizacion 0xFAB0FAB1")
    i = words.index(SYNC) + 1
    out, seen = [], set()
    while i < len(words):
        sel = words[i]
        i += 1
        if (sel >> DESYNC_BIT) & 1:            # palabra de desincronizacion: fin
            break
        if i + n_rows > len(words):
            sys.exit("ERROR: bitstream truncado dentro de un frame")
        data = words[i:i + n_rows]
        i += n_rows

        col = sel >> 27
        onehot = sel & ((1 << frames_per_col) - 1)
        if onehot == 0 or onehot & (onehot - 1):
            sys.exit(f"ERROR: la seleccion {sel:#010x} no es one-hot en [{frames_per_col-1}:0]")
        addr = col * frames_per_col + onehot.bit_length() - 1
        if addr in seen:
            print(f"AVISO: el frame con addr {addr} aparece mas de una vez", file=sys.stderr)
        seen.add(addr)

        frame = BORDER_WORD | (BORDER_WORD << (bits * (n_rows + 1)))   # filas 0 y n_rows+1
        for k, w in enumerate(data):            # palabra k -> fila n_rows-k
            frame |= w << (bits * (n_rows - k))
        out.append((addr, frame))
    return out


def write_hex(frames, path, n_rows, bits, n_strobe):
    frame_w = bits * (n_rows + 2)
    addr_w = (n_strobe - 1).bit_length()
    dr_w = frame_w + addr_w
    assert dr_w % 4 == 0, "DR_W no es multiplo de 4: ajustar el formato hex"
    with open(path, "w") as f:
        for addr, fr in frames:
            assert addr < n_strobe
            f.write(f"{(addr << frame_w) | fr:0{dr_w // 4}x}\n")
    return frame_w, addr_w, dr_w


# --------------------------------------------------------------------------
# Auto-prueba: modelo independiente del hardware (ConfigFSM + Frame_Data_Reg +
# Frame_Select), alimentado palabra a palabra como lo haria la UART/bitbang.
# --------------------------------------------------------------------------
def hw_model(words, n_rows, bits, frames_per_col, n_cols):
    UNSYNCED, SYNC_HEADER, WRITE = 0, 1, 2
    state, row_index, far = UNSYNCED, 0, 0
    reg = {r: None for r in range(1, n_rows + 1)}    # Frame_Data_Reg por Row
    strobes = []                                     # (strobe_index, FrameData_int)
    for w in words:
        if state == UNSYNCED:
            if w == SYNC:
                state = SYNC_HEADER
        elif state == SYNC_HEADER:
            if (w >> DESYNC_BIT) & 1:
                state = UNSYNCED
            else:
                far, row_index, state = w, n_rows, WRITE
        else:
            reg[row_index] = w                       # row_select == row_index
            row_index -= 1
            if row_index == 0:                       # ultima palabra -> LongFrameStrobe
                state = SYNC_HEADER
                fd = BORDER_WORD | (BORDER_WORD << (bits * (n_rows + 1)))
                for r in range(1, n_rows + 1):
                    fd |= reg[r] << (bits * r)
                col = (far >> 27) & 0x1F
                for c in range(n_cols):              # Frame_Select por columna
                    if c == col:
                        for b in range(frames_per_col):
                            if (far >> b) & 1:
                                strobes.append((c * frames_per_col + b, fd))
    return strobes


def selftest():
    n_rows, bits, fpc, n_cols = 14, 32, 20, 10
    rnd = random.Random(7)
    # Primer frame = el real de tu .bin (xxd); el resto aleatorio con el mismo esquema
    first = [0xe5c80000, 0xebd40000, 0xe1c00000, 0xe7cc0000, 0xe1c00000, 0xd1980000,
             0xdb940000, 0xdf980000, 0xcf880000, 0xcbdc0000, 0xe1c00000, 0xebd40000,
             0xe3c40000, 0xe9d00000]
    words = [0x00AAFF01, 1, 0, 0, SYNC]
    order = [(c, f) for c in range(n_cols) for f in range(fpc)]
    for k, (c, f) in enumerate(order):
        words.append((c << 27) | (1 << f))
        words += first if k == 0 else [rnd.getrandbits(32) for _ in range(n_rows)]
    words.append(1 << DESYNC_BIT)
    assert len(words) == 3006                        # igual que tu .bin
    assert [hex(x) for x in words[:5]] == ['0xaaff01', '0x1', '0x0', '0x0', '0xfab0fab1']

    mine = parse_frames(words, n_rows, bits, fpc)
    ref = hw_model(words, n_rows, bits, fpc, n_cols)
    assert mine == ref, "el conversor no coincide con el modelo del hardware"
    assert [a for a, _ in mine] == list(range(200))
    fd0 = mine[0][1]
    assert (fd0 >> 0) & 0xFFFFFFFF == BORDER_WORD and (fd0 >> 480) == BORDER_WORD
    assert (fd0 >> (32 * 14)) & 0xFFFFFFFF == first[0]     # 1a palabra -> fila 14
    assert (fd0 >> (32 * 1)) & 0xFFFFFFFF == first[13]     # ultima palabra -> fila 1
    write_hex(mine, "/tmp/selftest.hex", n_rows, bits, n_cols * fpc)
    lines = open("/tmp/selftest.hex").read().split()
    assert len(lines) == 200 and all(len(l) == 130 for l in lines)
    print("selftest OK: 200 frames, 130 digitos hex/linea, coincide con el modelo ConfigFSM/Frame_Data_Reg/Frame_Select")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("bin", nargs="?")
    ap.add_argument("hex", nargs="?")
    ap.add_argument("--rows", type=int, default=14, help="NumberOfRows de eFPGA_top (filas con datos)")
    ap.add_argument("--bits", type=int, default=32, help="FrameBitsPerRow")
    ap.add_argument("--frames-per-col", type=int, default=20, help="MaxFramesPerCol")
    ap.add_argument("--cols", type=int, default=10)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        selftest()
        sys.exit(0)
    if not (a.bin and a.hex):
        ap.error("falta <entrada.bin> <salida.hex>")
    words = read_words(a.bin)
    frames = parse_frames(words, a.rows, a.bits, a.frames_per_col)
    fw, aw, dw = write_hex(frames, a.hex, a.rows, a.bits, a.cols * a.frames_per_col)
    print(f"{len(frames)} frames -> {a.hex}  (FRAME_W={fw}, ADDR_W={aw}, DR_W={dw})")
