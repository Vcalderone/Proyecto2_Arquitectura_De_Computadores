"""Two-pass assembler for the Espino Core (RV32E), per docs/assembler.md.

Pass 1 walks the file once, building the symbol table (labels and .equ
constants) against a running address counter, and determining how many
bytes each line occupies (fixed for real instructions, 4 or 8 for `li`).

Pass 2 walks the parsed lines again and encodes each one, now that every
label -- including forward references -- has a known address.
"""

import re

from errors import AssemblerError
from isa import (
    ABI_NAMES,
    ALL_SHIFT_MNEMONICS,
    BRANCHES,
    I_ARITH,
    LOADS,
    OPCODE_AUIPC,
    OPCODE_BRANCH,
    OPCODE_I_ARITH,
    OPCODE_JAL,
    OPCODE_JALR,
    OPCODE_LOAD,
    OPCODE_LUI,
    OPCODE_R,
    OPCODE_STORE,
    R_TYPE,
    SHIFT_I_TYPE,
    SHIFT_R_TYPE,
    STORES,
    encode_b,
    encode_i,
    encode_j,
    encode_r,
    encode_s,
    encode_u,
)

RAM_WORDS = 512
RAM_BYTES = RAM_WORDS * 4

REAL_FIXED_1WORD = set(R_TYPE) | set(I_ARITH) | set(LOADS) | set(STORES) | set(BRANCHES) | {
    "jal",
    "jalr",
    "lui",
    "auipc",
}
PSEUDO_FIXED_1WORD = {"nop", "mv", "not", "neg", "j", "jr", "ret", "beqz", "bnez", "bltz", "la"}

LABEL_RE = re.compile(r"^([A-Za-z_]\w*)\s*:\s*(.*)$")
IDENT_RE = re.compile(r"^[A-Za-z_]\w*$")
MEM_OPERAND_RE = re.compile(r"^(.*)\((.*)\)$")
REGISTER_RE = re.compile(r"^x(\d+)$")


class Line:
    __slots__ = ("lineno", "label", "kind", "name", "operands", "raw")

    def __init__(self, lineno, label, kind, name, operands, raw):
        self.lineno = lineno
        self.label = label
        self.kind = kind  # 'label_only' | 'directive' | 'insn'
        self.name = name
        self.operands = operands
        self.raw = raw


def split_operands(text):
    return [tok.strip() for tok in text.split(",") if tok.strip() != ""]


def parse_lines(text):
    lines = []
    for lineno, raw in enumerate(text.splitlines(), start=1):
        code = raw.split("#", 1)[0].strip()
        if not code:
            continue

        label = None
        m = LABEL_RE.match(code)
        if m:
            label = m.group(1)
            code = m.group(2).strip()

        if not code:
            lines.append(Line(lineno, label, "label_only", None, [], raw))
            continue

        parts = code.split(None, 1)
        name = parts[0]
        rest = parts[1].strip() if len(parts) > 1 else ""

        if name.startswith("."):
            lines.append(Line(lineno, label, "directive", name.lower(), split_operands(rest), raw))
        else:
            lines.append(Line(lineno, label, "insn", name.lower(), split_operands(rest), raw))
    return lines


def parse_number(tok):
    """Parses a plain numeric literal (decimal/hex/binary, optionally signed).
    Raises ValueError if `tok` isn't a numeric literal at all.
    """
    s = tok.strip()
    sign = 1
    if s.startswith("+"):
        s = s[1:]
    elif s.startswith("-"):
        sign = -1
        s = s[1:]
    low = s.lower()
    if low.startswith("0x"):
        return sign * int(s, 16)
    if low.startswith("0b"):
        return sign * int(s, 2)
    return sign * int(s, 10)


def resolve_value(tok, symtab, lineno, what):
    try:
        return parse_number(tok)
    except ValueError:
        pass
    if tok in symtab:
        return symtab[tok]
    raise AssemblerError(lineno, f"{what} no definida: '{tok}'")


def resolve_register(tok, lineno):
    t = tok.strip()
    low = t.lower()
    m = REGISTER_RE.match(low)
    if m:
        n = int(m.group(1))
        if 0 <= n <= 15:
            return n
        raise AssemblerError(lineno, f"x{n} no existe: RV32E solo tiene x0-x15")
    if low in ABI_NAMES:
        return ABI_NAMES[low]
    raise AssemblerError(lineno, f"registro desconocido: '{t}'")


def parse_mem_operand(tok, lineno):
    m = MEM_OPERAND_RE.match(tok.strip())
    if not m:
        raise AssemblerError(lineno, f"operando de memoria inválido: '{tok}' (se esperaba imm(rs1))")
    imm_str = m.group(1).strip()
    reg_str = m.group(2).strip()
    if imm_str == "":
        imm_str = "0"
    return imm_str, reg_str


def check_range(value, lo, hi, lineno, what):
    if not (lo <= value <= hi):
        raise AssemblerError(lineno, f"{what} fuera de rango ({value}): debe estar entre {lo} y {hi}")


def check_branch_range(offset, lineno):
    if offset % 2 != 0:
        raise AssemblerError(lineno, f"salto a dirección impar (offset {offset})")
    if not (-4096 <= offset <= 4094):
        raise AssemblerError(lineno, f"salto fuera de alcance: offset {offset} bytes (máximo ±4096)")


def check_jal_range(offset, lineno):
    if offset % 2 != 0:
        raise AssemblerError(lineno, f"salto a dirección impar (offset {offset})")
    if not (-1048576 <= offset <= 1048574):
        raise AssemblerError(lineno, f"salto fuera de alcance: offset {offset} bytes (máximo ±1048576)")


def to_signed32(u):
    return u - 0x100000000 if u >= 0x80000000 else u


def li_encode(rd, value, lineno):
    """Implements the li expansion of docs/assembler.md section 6, including
    the +0x800 sign correction for the general case. Shared by pass 1 (which
    only needs len(...)) and pass 2 (which needs the actual words), so the
    two can never disagree about how many instructions a given constant
    takes.
    """
    if not (-0x80000000 <= value <= 0xFFFFFFFF):
        raise AssemblerError(lineno, f"'li': el valor {value} no cabe en 32 bits")

    u = value & 0xFFFFFFFF
    s = to_signed32(u)

    if -2048 <= s <= 2047:
        return [encode_i(OPCODE_I_ARITH, rd, 0b000, 0, s)]

    if (u & 0xFFF) == 0:
        return [encode_u(OPCODE_LUI, rd, (u >> 12) & 0xFFFFF)]

    hi = (s + 0x800) >> 12
    lo = s - (hi << 12)
    return [
        encode_u(OPCODE_LUI, rd, hi & 0xFFFFF),
        encode_i(OPCODE_I_ARITH, rd, 0b000, rd, lo),
    ]


class Assembler:
    def __init__(self, allow_shifts=False):
        self.allow_shifts = allow_shifts

    def assemble(self, text):
        lines = parse_lines(text)
        symtab = {}
        sized = []
        addr = 0

        for ln in lines:
            if ln.label is not None:
                self._define_symbol(symtab, ln.label, addr, ln.lineno, "etiqueta")

            if ln.kind == "label_only":
                continue

            if ln.kind == "directive":
                if ln.name == ".equ":
                    self._handle_equ(ln, symtab)
                    continue
                if ln.name == ".word":
                    if len(ln.operands) == 0:
                        raise AssemblerError(ln.lineno, ".word requiere al menos un valor")
                    size = 4 * len(ln.operands)
                elif ln.name in (".section", ".text", ".global"):
                    continue
                else:
                    raise AssemblerError(ln.lineno, f"directiva desconocida: '{ln.name}'")
            elif ln.kind == "insn":
                size = self._instruction_size(ln, symtab)
            else:
                continue

            if addr + size > RAM_BYTES:
                raise AssemblerError(
                    ln.lineno,
                    f"el programa excede las {RAM_WORDS} palabras de RAM disponibles ({RAM_BYTES} bytes)",
                )
            sized.append((ln, addr, size))
            addr += size

        words = []
        for ln, address, size in sized:
            if ln.kind == "directive":
                for tok in ln.operands:
                    val = resolve_value(tok, symtab, ln.lineno, "valor")
                    words.append(val & 0xFFFFFFFF)
            else:
                encoded = self._encode_instruction(ln, address, symtab)
                if len(encoded) * 4 != size:
                    raise AssemblerError(
                        ln.lineno,
                        f"tamaño inconsistente para '{ln.name}': se reservaron {size} bytes, se generaron {len(encoded) * 4}",
                    )
                words.extend(encoded)

        return words

    # -- symbol table ----------------------------------------------------

    def _define_symbol(self, symtab, name, value, lineno, kind):
        if name in symtab:
            raise AssemblerError(lineno, f"{kind} duplicada: '{name}'")
        symtab[name] = value

    def _handle_equ(self, ln, symtab):
        if len(ln.operands) != 2:
            raise AssemblerError(ln.lineno, ".equ requiere NOMBRE, valor")
        name, val_tok = ln.operands
        if not IDENT_RE.match(name):
            raise AssemblerError(ln.lineno, f"nombre de constante inválido: '{name}'")
        value = resolve_value(val_tok, symtab, ln.lineno, "constante")
        self._define_symbol(symtab, name, value, ln.lineno, "constante")

    # -- pass 1: sizing ----------------------------------------------------

    def _instruction_size(self, ln, symtab):
        m = ln.name

        if m in ALL_SHIFT_MNEMONICS:
            if not self.allow_shifts:
                raise AssemblerError(
                    ln.lineno,
                    f"'{m}': los shifts ejecutan como ADD en este core (usa --allow-shifts si sabes lo que haces)",
                )
            return 4

        if m in REAL_FIXED_1WORD or m in PSEUDO_FIXED_1WORD:
            return 4

        if m == "li":
            if len(ln.operands) != 2:
                raise AssemblerError(ln.lineno, f"'li' espera 2 operandos (rd, imm), recibió {len(ln.operands)}")
            value = resolve_value(ln.operands[1], symtab, ln.lineno, "constante")
            return 4 * len(li_encode(0, value, ln.lineno))

        raise AssemblerError(ln.lineno, f"mnemónico desconocido: '{m}'")

    # -- pass 2: encoding ----------------------------------------------------

    def _check_arity(self, ln, n):
        if len(ln.operands) != n:
            raise AssemblerError(
                ln.lineno, f"'{ln.name}' espera {n} operando(s), recibió {len(ln.operands)}"
            )

    def _reg(self, tok, lineno):
        return resolve_register(tok, lineno)

    def _imm(self, tok, symtab, lineno):
        return resolve_value(tok, symtab, lineno, "inmediato")

    def _label_addr(self, tok, symtab, lineno):
        if tok in symtab:
            return symtab[tok]
        raise AssemblerError(lineno, f"etiqueta no definida: '{tok}'")

    def _encode_instruction(self, ln, address, symtab):
        m = ln.name
        ops = ln.operands
        lineno = ln.lineno

        if m in R_TYPE:
            self._check_arity(ln, 3)
            rd, rs1, rs2 = (self._reg(o, lineno) for o in ops)
            funct7, funct3 = R_TYPE[m]
            return [encode_r(OPCODE_R, rd, funct3, rs1, rs2, funct7)]

        if m in SHIFT_R_TYPE:
            self._check_arity(ln, 3)
            rd, rs1, rs2 = (self._reg(o, lineno) for o in ops)
            funct7, funct3 = SHIFT_R_TYPE[m]
            return [encode_r(OPCODE_R, rd, funct3, rs1, rs2, funct7)]

        if m in I_ARITH:
            self._check_arity(ln, 3)
            rd = self._reg(ops[0], lineno)
            rs1 = self._reg(ops[1], lineno)
            imm = self._imm(ops[2], symtab, lineno)
            check_range(imm, -2048, 2047, lineno, "inmediato")
            return [encode_i(OPCODE_I_ARITH, rd, I_ARITH[m], rs1, imm)]

        if m in SHIFT_I_TYPE:
            self._check_arity(ln, 3)
            rd = self._reg(ops[0], lineno)
            rs1 = self._reg(ops[1], lineno)
            shamt = self._imm(ops[2], symtab, lineno)
            check_range(shamt, 0, 31, lineno, "shamt")
            funct7, funct3 = SHIFT_I_TYPE[m]
            return [encode_i(OPCODE_I_ARITH, rd, funct3, rs1, (funct7 << 5) | shamt)]

        if m in LOADS:
            self._check_arity(ln, 2)
            rd = self._reg(ops[0], lineno)
            imm_str, rs1_str = parse_mem_operand(ops[1], lineno)
            rs1 = self._reg(rs1_str, lineno)
            imm = self._imm(imm_str, symtab, lineno)
            check_range(imm, -2048, 2047, lineno, "inmediato")
            return [encode_i(OPCODE_LOAD, rd, LOADS[m], rs1, imm)]

        if m in STORES:
            self._check_arity(ln, 2)
            rs2 = self._reg(ops[0], lineno)
            imm_str, rs1_str = parse_mem_operand(ops[1], lineno)
            rs1 = self._reg(rs1_str, lineno)
            imm = self._imm(imm_str, symtab, lineno)
            check_range(imm, -2048, 2047, lineno, "inmediato")
            return [encode_s(OPCODE_STORE, STORES[m], rs1, rs2, imm)]

        if m in BRANCHES:
            self._check_arity(ln, 3)
            rs1 = self._reg(ops[0], lineno)
            rs2 = self._reg(ops[1], lineno)
            target = self._label_addr(ops[2], symtab, lineno)
            offset = target - address
            check_branch_range(offset, lineno)
            return [encode_b(OPCODE_BRANCH, BRANCHES[m], rs1, rs2, offset)]

        if m == "jal":
            self._check_arity(ln, 2)
            rd = self._reg(ops[0], lineno)
            target = self._label_addr(ops[1], symtab, lineno)
            offset = target - address
            check_jal_range(offset, lineno)
            return [encode_j(OPCODE_JAL, rd, offset)]

        if m == "jalr":
            self._check_arity(ln, 2)
            rd = self._reg(ops[0], lineno)
            imm_str, rs1_str = parse_mem_operand(ops[1], lineno)
            rs1 = self._reg(rs1_str, lineno)
            imm = self._imm(imm_str, symtab, lineno)
            check_range(imm, -2048, 2047, lineno, "inmediato")
            return [encode_i(OPCODE_JALR, rd, 0b000, rs1, imm)]

        if m == "lui" or m == "auipc":
            self._check_arity(ln, 2)
            rd = self._reg(ops[0], lineno)
            imm20 = self._imm(ops[1], symtab, lineno)
            check_range(imm20, 0, 0xFFFFF, lineno, "inmediato de lui/auipc")
            opcode = OPCODE_LUI if m == "lui" else OPCODE_AUIPC
            return [encode_u(opcode, rd, imm20)]

        # -- pseudo-instructions --

        if m == "nop":
            self._check_arity(ln, 0)
            return [encode_i(OPCODE_I_ARITH, 0, 0b000, 0, 0)]

        if m == "mv":
            self._check_arity(ln, 2)
            rd, rs = (self._reg(o, lineno) for o in ops)
            return [encode_i(OPCODE_I_ARITH, rd, 0b000, rs, 0)]

        if m == "not":
            self._check_arity(ln, 2)
            rd, rs = (self._reg(o, lineno) for o in ops)
            return [encode_i(OPCODE_I_ARITH, rd, 0b100, rs, -1)]

        if m == "neg":
            self._check_arity(ln, 2)
            rd, rs = (self._reg(o, lineno) for o in ops)
            return [encode_r(OPCODE_R, rd, 0b000, 0, rs, 0b0100000)]

        if m == "j":
            self._check_arity(ln, 1)
            target = self._label_addr(ops[0], symtab, lineno)
            offset = target - address
            check_jal_range(offset, lineno)
            return [encode_j(OPCODE_JAL, 0, offset)]

        if m == "jr":
            self._check_arity(ln, 1)
            rs = self._reg(ops[0], lineno)
            return [encode_i(OPCODE_JALR, 0, 0b000, rs, 0)]

        if m == "ret":
            self._check_arity(ln, 0)
            return [encode_i(OPCODE_JALR, 0, 0b000, 1, 0)]

        if m in ("beqz", "bnez", "bltz"):
            self._check_arity(ln, 2)
            rs = self._reg(ops[0], lineno)
            target = self._label_addr(ops[1], symtab, lineno)
            offset = target - address
            check_branch_range(offset, lineno)
            funct3 = {"beqz": 0b000, "bnez": 0b001, "bltz": 0b100}[m]
            return [encode_b(OPCODE_BRANCH, funct3, rs, 0, offset)]

        if m == "li":
            self._check_arity(ln, 2)
            rd = self._reg(ops[0], lineno)
            value = self._imm(ops[1], symtab, lineno)
            return li_encode(rd, value, lineno)

        if m == "la":
            self._check_arity(ln, 2)
            rd = self._reg(ops[0], lineno)
            target = self._label_addr(ops[1], symtab, lineno)
            check_range(target, -2048, 2047, lineno, "dirección")
            return [encode_i(OPCODE_I_ARITH, rd, 0b000, 0, target)]

        raise AssemblerError(lineno, f"mnemónico desconocido: '{m}'")


def assemble_text(text, allow_shifts=False):
    return Assembler(allow_shifts=allow_shifts).assemble(text)


def format_hex(words):
    if not words:
        return ""
    return "\n".join(f"{w & 0xFFFFFFFF:08x}" for w in words) + "\n"


def assemble_file(input_path, output_path, allow_shifts=False):
    with open(input_path, "r", encoding="utf-8") as f:
        text = f.read()
    words = assemble_text(text, allow_shifts=allow_shifts)
    with open(output_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(format_hex(words))
    return words
