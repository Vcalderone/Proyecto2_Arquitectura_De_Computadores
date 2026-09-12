"""Disassembler: the inverse of core.py's pass 2. Not required by the
spec, but it buys a round-trip test (assemble -> disassemble -> reassemble
-> compare) that catches encoding bugs a golden-file comparison can't, since
it doesn't depend on already knowing the right answer.

Every instruction address gets its own label (L<addr in hex>), and control
transfers reference those labels, so the output text is always directly
reassembleable by core.py without any special-casing.
"""

from isa import (
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
    field_funct3,
    field_funct7,
    field_opcode,
    field_rd,
    field_rs1,
    field_rs2,
    imm_b,
    imm_i,
    imm_j,
    imm_s,
    imm_u,
)

_REV_R = {v: k for k, v in R_TYPE.items()}
_REV_SHIFT_R = {v: k for k, v in SHIFT_R_TYPE.items()}
_REV_I_ARITH = {v: k for k, v in I_ARITH.items()}
_REV_SHIFT_I = {v: k for k, v in SHIFT_I_TYPE.items()}
_REV_LOADS = {v: k for k, v in LOADS.items()}
_REV_STORES = {v: k for k, v in STORES.items()}
_REV_BRANCHES = {v: k for k, v in BRANCHES.items()}


def _label(addr):
    return f"L{addr:04x}"


def decode_one(word, addr, allow_shifts=False):
    """Returns the operand text for `word` (mnemonic + operands, no label)."""
    opcode = field_opcode(word)
    rd = field_rd(word)
    rs1 = field_rs1(word)
    rs2 = field_rs2(word)
    funct3 = field_funct3(word)
    funct7 = field_funct7(word)

    if opcode == OPCODE_R:
        key = (funct7, funct3)
        if key in _REV_R:
            return f"{_REV_R[key]} x{rd}, x{rs1}, x{rs2}"
        if allow_shifts and key in _REV_SHIFT_R:
            return f"{_REV_SHIFT_R[key]} x{rd}, x{rs1}, x{rs2}"
        raise ValueError(f"R-type desconocido en 0x{addr:04x}: funct7={funct7:#09b} funct3={funct3:#05b}")

    if opcode == OPCODE_I_ARITH:
        if funct3 in _REV_I_ARITH:
            imm = imm_i(word)
            return f"{_REV_I_ARITH[funct3]} x{rd}, x{rs1}, {imm}"
        if allow_shifts and (funct7, funct3) in _REV_SHIFT_I:
            shamt = rs2  # imm[4:0] lives in the rs2 field position
            return f"{_REV_SHIFT_I[(funct7, funct3)]} x{rd}, x{rs1}, {shamt}"
        raise ValueError(f"I-arith desconocido en 0x{addr:04x}: funct3={funct3:#05b}")

    if opcode == OPCODE_LOAD:
        imm = imm_i(word)
        return f"{_REV_LOADS[funct3]} x{rd}, {imm}(x{rs1})"

    if opcode == OPCODE_STORE:
        imm = imm_s(word)
        return f"{_REV_STORES[funct3]} x{rs2}, {imm}(x{rs1})"

    if opcode == OPCODE_BRANCH:
        offset = imm_b(word)
        return f"{_REV_BRANCHES[funct3]} x{rs1}, x{rs2}, {_label(addr + offset)}"

    if opcode == OPCODE_JAL:
        offset = imm_j(word)
        return f"jal x{rd}, {_label(addr + offset)}"

    if opcode == OPCODE_JALR:
        imm = imm_i(word)
        return f"jalr x{rd}, {imm}(x{rs1})"

    if opcode == OPCODE_LUI:
        imm20 = imm_u(word)
        return f"lui x{rd}, {hex(imm20)}"

    if opcode == OPCODE_AUIPC:
        imm20 = imm_u(word)
        return f"auipc x{rd}, {hex(imm20)}"

    raise ValueError(f"opcode desconocido en 0x{addr:04x}: {opcode:#09b}")


def disassemble(words, allow_shifts=False):
    """Returns a list of text lines, one per word, each prefixed with its
    own address label so the output is directly reassembleable.
    """
    lines = []
    for i, word in enumerate(words):
        addr = i * 4
        text = decode_one(word, addr, allow_shifts=allow_shifts)
        lines.append(f"{_label(addr)}: {text}")
    return lines
