"""Encoding tables and the six format encoders/decoders for the Espino Core
(RV32E) ISA, per docs/assembler.md. No knowledge of the SoC memory map lives
here on purpose -- this module only knows about opcodes, funct3/funct7 and
bit layouts.
"""

# ---------------------------------------------------------------------------
# Registers: RV32E only has x0-x15.
# ---------------------------------------------------------------------------

ABI_NAMES = {
    "zero": 0,
    "ra": 1,
    "sp": 2,
    "gp": 3,
    "tp": 4,
    "t0": 5,
    "t1": 6,
    "t2": 7,
    "s0": 8,
    "fp": 8,
    "s1": 9,
    "a0": 10,
    "a1": 11,
    "a2": 12,
    "a3": 13,
    "a4": 14,
    "a5": 15,
}

# ---------------------------------------------------------------------------
# Opcodes
# ---------------------------------------------------------------------------

OPCODE_R = 0b0110011
OPCODE_I_ARITH = 0b0010011
OPCODE_LOAD = 0b0000011
OPCODE_STORE = 0b0100011
OPCODE_BRANCH = 0b1100011
OPCODE_JAL = 0b1101111
OPCODE_JALR = 0b1100111
OPCODE_LUI = 0b0110111
OPCODE_AUIPC = 0b0010111

# mnemonic -> (funct7, funct3), opcode OPCODE_R
R_TYPE = {
    "add": (0b0000000, 0b000),
    "sub": (0b0100000, 0b000),
    "slt": (0b0000000, 0b010),
    "sltu": (0b0000000, 0b011),
    "xor": (0b0000000, 0b100),
    "or": (0b0000000, 0b110),
    "and": (0b0000000, 0b111),
}

# mnemonic -> (funct7, funct3), opcode OPCODE_R -- disabled ALU ops, gated by --allow-shifts
SHIFT_R_TYPE = {
    "sll": (0b0000000, 0b001),
    "srl": (0b0000000, 0b101),
    "sra": (0b0100000, 0b101),
}

# mnemonic -> funct3, opcode OPCODE_I_ARITH
I_ARITH = {
    "addi": 0b000,
    "slti": 0b010,
    "sltiu": 0b011,
    "xori": 0b100,
    "ori": 0b110,
    "andi": 0b111,
}

# mnemonic -> (funct7, funct3), opcode OPCODE_I_ARITH, imm = shamt[4:0] -- gated by --allow-shifts
SHIFT_I_TYPE = {
    "slli": (0b0000000, 0b001),
    "srli": (0b0000000, 0b101),
    "srai": (0b0100000, 0b101),
}

ALL_SHIFT_MNEMONICS = set(SHIFT_R_TYPE) | set(SHIFT_I_TYPE)

# mnemonic -> funct3, opcode OPCODE_LOAD
LOADS = {
    "lb": 0b000,
    "lh": 0b001,
    "lw": 0b010,
    "lbu": 0b100,
    "lhu": 0b101,
}

# mnemonic -> funct3, opcode OPCODE_STORE
STORES = {
    "sb": 0b000,
    "sh": 0b001,
    "sw": 0b010,
}

# mnemonic -> funct3, opcode OPCODE_BRANCH
BRANCHES = {
    "beq": 0b000,
    "bne": 0b001,
    "blt": 0b100,
    "bge": 0b101,
    "bltu": 0b110,
    "bgeu": 0b111,
}


# ---------------------------------------------------------------------------
# Encoders. Each returns an unsigned 32-bit int. Immediates are accepted as
# plain Python ints (may be negative) and masked to the field width; callers
# are responsible for range-checking before calling these.
# ---------------------------------------------------------------------------


def encode_r(opcode, rd, funct3, rs1, rs2, funct7):
    return (
        ((funct7 & 0x7F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def encode_i(opcode, rd, funct3, rs1, imm):
    imm12 = imm & 0xFFF
    return (
        (imm12 << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def encode_s(opcode, funct3, rs1, rs2, imm):
    imm12 = imm & 0xFFF
    hi = (imm12 >> 5) & 0x7F
    lo = imm12 & 0x1F
    return (
        (hi << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | (lo << 7)
        | (opcode & 0x7F)
    )


def encode_b(opcode, funct3, rs1, rs2, imm):
    v = imm & 0x1FFF
    bit12 = (v >> 12) & 0x1
    bits10_5 = (v >> 5) & 0x3F
    bits4_1 = (v >> 1) & 0xF
    bit11 = (v >> 11) & 0x1
    return (
        (bit12 << 31)
        | (bits10_5 << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | (bits4_1 << 8)
        | (bit11 << 7)
        | (opcode & 0x7F)
    )


def encode_u(opcode, rd, imm20):
    v = imm20 & 0xFFFFF
    return (v << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)


def encode_j(opcode, rd, imm):
    v = imm & 0x1FFFFF
    bit20 = (v >> 20) & 0x1
    bits10_1 = (v >> 1) & 0x3FF
    bit11 = (v >> 11) & 0x1
    bits19_12 = (v >> 12) & 0xFF
    return (
        (bit20 << 31)
        | (bits10_1 << 21)
        | (bit11 << 20)
        | (bits19_12 << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


# ---------------------------------------------------------------------------
# Decoders (used by the disassembler). Mirror espino_decoder.v:94-100 exactly.
# ---------------------------------------------------------------------------


def sign_extend(value, bits_n):
    mask = 1 << (bits_n - 1)
    return (value ^ mask) - mask


def field_opcode(word):
    return word & 0x7F


def field_rd(word):
    return (word >> 7) & 0x1F


def field_funct3(word):
    return (word >> 12) & 0x7


def field_rs1(word):
    return (word >> 15) & 0x1F


def field_rs2(word):
    return (word >> 20) & 0x1F


def field_funct7(word):
    return (word >> 25) & 0x7F


def imm_i(word):
    return sign_extend((word >> 20) & 0xFFF, 12)


def imm_s(word):
    v = (((word >> 25) & 0x7F) << 5) | ((word >> 7) & 0x1F)
    return sign_extend(v, 12)


def imm_b(word):
    v = (
        (((word >> 31) & 0x1) << 12)
        | (((word >> 7) & 0x1) << 11)
        | (((word >> 25) & 0x3F) << 5)
        | (((word >> 8) & 0xF) << 1)
    )
    return sign_extend(v, 13)


def imm_u(word):
    """The raw 20-bit field as used by lui/auipc -- not sign-extended."""
    return (word >> 12) & 0xFFFFF


def imm_j(word):
    v = (
        (((word >> 31) & 0x1) << 20)
        | (((word >> 12) & 0xFF) << 12)
        | (((word >> 20) & 0x1) << 11)
        | (((word >> 21) & 0x3FF) << 1)
    )
    return sign_extend(v, 21)
