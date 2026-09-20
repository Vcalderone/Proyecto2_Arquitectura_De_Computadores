# Assembler del Espino Core

Este documento describe el assembler propio del proyecto (`assembler/`), que traduce programas en assembly RV32E, como `sw/game.s`, a archivos `.hex` que el RTL carga con `$readmemh`. Es el contrato entre el código del assembler, sus tests y los programas de `sw/`.

## 1. Restricción: no se invoca ningún assembler externo

El enunciado prohíbe usar un assembler externo (por ejemplo `riscv64-unknown-elf-as`). Todo el flujo de `.s` a `.hex` pasa por `assembler/asm.py`, escrito en Python 3 sin dependencias, y ni el `Makefile` ni los tests invocan otra herramienta.

Para comprobar que el assembler es correcto, el repositorio traía tres programas de ejemplo con su `.hex` ya generado (`blink`, `7seg` y `buttons_leds`). El comando

```bash
make asm-all
```

regenera con el assembler del grupo los tres `.hex` de ejemplo, además de `game.hex`, y los tres primeros salen **byte a byte idénticos** a los que venían en el repo. `assembler/tests/test_golden.py` hace esa comparación de forma automática.

Por esa razón se eliminó `sw/Makefile`. Ese archivo llamaba a `riscv64-unknown-elf-as`, y su regla `%.hex: %.s` alcanzaba también a `game.s`. Un `make` dentro de `sw/` habría regenerado el firmware del juego con la herramienta que el enunciado prohíbe. Ahora existe una sola regla, en el `Makefile` de la raíz, que usa nuestro assembler.

## 2. Uso

```
python3 assembler/asm.py ENTRADA.s [-o SALIDA.hex] [-D NOMBRE=VALOR ...] [--allow-shifts]
```

| Opción                  | Efecto                                                                                     |
|-------------------------|--------------------------------------------------------------------------------------------|
| `ENTRADA.s`             | Archivo de entrada (obligatorio).                                                          |
| `-o`, `--output`        | Archivo `.hex` de salida. Por defecto, la entrada con extensión `.hex`.                    |
| `-D`, `--define`        | `NOMBRE=VALOR`: fija una constante y pisa el `.equ` del mismo nombre. Se puede repetir.    |
| `--allow-shifts`        | Acepta `sll`, `srl`, `sra`, `slli`, `srli` y `srai`.                                       |

Ejemplos:

```bash
python3 assembler/asm.py sw/game.s -o sw/game.hex
python3 assembler/asm.py sw/game.s -o sw/game_sim.hex -D CYCLES_PER_TENTH=2500
python3 assembler/asm.py sw/game.s -o sw/game_sim_r4.hex -D CYCLES_PER_TENTH=2500 -D RONDAS=4
```

El valor de `-D` acepta los mismos literales que el assembler: decimal, `0x` y `0b`. Si el nombre no existe como `.equ` en el archivo, `-D` igual lo define, de modo que se puede usar para pasar constantes que el programa solo lee. Un `-D` mal formado (sin `=`, o con valor no numérico) termina con error y código de salida 1. Al terminar, el assembler imprime cuántas palabras generó.

**Por qué los shifts se rechazan por defecto.** La ALU del Espino Core, para ahorrar LUTs, ejecuta `sll`, `srl` y `sra` (y sus variantes con inmediato) como una suma. El decodificador los reconoce bien, pero el resultado es el de un `add`. Si el assembler los emitiera sin avisar, se obtendría un binario que ensambla sin errores y corre mal, que es el peor tipo de falla porque no deja pistas. Por eso el assembler los rechaza con un mensaje explicativo, y `--allow-shifts` existe solo para quien sepa lo que hace, por ejemplo con una ALU propia. `sw/game.s` evita los shifts: desplaza sumando un registro consigo mismo (`add x7, x7, x7`).

## 3. Sintaxis aceptada

- **Una instrucción por línea.**
- **Comentarios** con `#`, hasta el fin de la línea. Una línea que solo tiene comentario, o que está en blanco, se ignora.
- **Etiquetas** con la forma `nombre:`. Pueden ir solas en su línea, y entonces apuntan a la instrucción siguiente, o delante de una instrucción en la misma línea. Un nombre es una letra o `_` seguida de letras, dígitos o `_`.
- **Mayúsculas y minúsculas.** Los mnemónicos, los registros y las directivas no distinguen mayúsculas (`ADDI X1, X2, 5` equivale a `addi x1, x2, 5`). Las etiquetas y los nombres de `.equ` sí las distinguen.
- **Operandos** separados por comas.
- **Acceso a memoria** con el formato `desplazamiento(registro)`, por ejemplo `lw x9, 8(x2)` o `sw x9, OFF_LEDS(x2)`. El desplazamiento puede ser un literal o una constante `.equ`, y si se omite vale 0: `jalr x0, (x1)`.
- **Literales numéricos:** decimal (`75`, `-585`), hexadecimal con prefijo `0x` (`0x04C11DB7`) y binario con prefijo `0b` (`0b1010`). Aceptan signo `+` o `-`.

## 4. Registros

El core implementa RV32E, que tiene 16 registros, de `x0` a `x15`. Se aceptan además los nombres ABI:

| ABI          | Registro | ABI  | Registro |
|--------------|----------|------|----------|
| `zero`       | x0       | `s1` | x9       |
| `ra`         | x1       | `a0` | x10      |
| `sp`         | x2       | `a1` | x11      |
| `gp`         | x3       | `a2` | x12      |
| `tp`         | x4       | `a3` | x13      |
| `t0`         | x5       | `a4` | x14      |
| `t1`         | x6       | `a5` | x15      |
| `t2`         | x7       | `s0`, `fp` | x8 |

Pedir `x16` o superior es un **error** ("x16 no existe: RV32E solo tiene x0-x15"), no un truncamiento silencioso. Los campos de registro de la instrucción tienen 5 bits, así que `x16` cabría en la codificación, y un programa con ese error ensamblaría sin quejas pero no significaría lo que el autor pensó. Un nombre que no es ni `xN` ni ABI también es error.

## 5. Directivas

| Directiva                    | Efecto                                                                                          |
|------------------------------|-------------------------------------------------------------------------------------------------|
| `.equ NOMBRE, valor`         | Define una constante. El valor es un literal u otra constante ya definida. No ocupa memoria.    |
| `.word v1, v2, ...`          | Emite una o más palabras de 32 bits literales. El valor puede ser un literal, una constante o una etiqueta. |
| `.section`, `.text`, `.global` | Se aceptan e ignoran. Existen para que el mismo archivo se lea bien con otras herramientas.   |

Cualquier otra directiva es un error. Un `.equ` con un nombre repetido también es error, salvo que el nombre venga fijado por `-D`, caso en que el `.equ` del archivo se ignora. Las constantes deben definirse antes de usarse.

## 6. Etiquetas, inmediatos y pseudo-instrucciones

### Dos pasadas

El assembler recorre el archivo dos veces.

1. **Primera pasada.** Va con un contador de dirección que parte en 0. Cada instrucción real ocupa 4 bytes. Cada etiqueta se anota en la tabla de símbolos con la dirección actual y cada `.equ` con su valor. Para saber cuánto ocupa cada línea, se calcula el largo de cada pseudo-instrucción (`li` puede ocupar 4 u 8 bytes, según el valor).
2. **Segunda pasada.** Con la tabla completa, codifica cada línea. En este punto una etiqueta ya tiene dirección aunque esté más adelante en el archivo, y así se resuelven las **referencias hacia adelante**: un `beq x9, x0, fin` puede aparecer antes de `fin:` porque en la primera pasada `fin` ya quedó registrada. Para un salto o bifurcación, el desplazamiento codificado es `dirección de la etiqueta - dirección de la instrucción`.

`li` comparte una sola función entre ambas pasadas, así que el tamaño que se reserva y el que se genera no pueden discrepar.

### Rangos de inmediato por formato

| Uso                                     | Rango permitido                     |
|-----------------------------------------|-------------------------------------|
| Formato I (`addi`, `andi`, ..., `lw`, `jalr`) y formato S (`sw`) | -2048 a 2047   |
| `shamt` de shifts (con `--allow-shifts`) | 0 a 31                             |
| Bifurcaciones (`beq`, `bne`, ...)       | desplazamiento par, de -4096 a 4094 bytes |
| `jal`, `j`                              | desplazamiento par, de -1.048.576 a 1.048.574 bytes |
| `lui`, `auipc`                          | 0 a 0xFFFFF (20 bits)               |
| `li`                                    | -2^31 a 2^32 - 1 (cabe en 32 bits)  |

Un valor fuera de rango produce un error con el número de línea, en vez de truncarse.

### Pseudo-instrucciones

Se traducen a instrucciones reales:

| Pseudo            | Expansión                       |
|-------------------|---------------------------------|
| `nop`             | `addi x0, x0, 0`                |
| `mv rd, rs`       | `addi rd, rs, 0`                |
| `not rd, rs`      | `xori rd, rs, -1`               |
| `neg rd, rs`      | `sub rd, x0, rs`                |
| `j etiqueta`      | `jal x0, etiqueta`              |
| `jr rs`           | `jalr x0, 0(rs)`                |
| `ret`             | `jalr x0, 0(x1)`                |
| `beqz rs, etiq`   | `beq rs, x0, etiq`              |
| `bnez rs, etiq`   | `bne rs, x0, etiq`              |
| `bltz rs, etiq`   | `blt rs, x0, etiq`              |
| `la rd, etiqueta` | `addi rd, x0, dirección`, y la dirección debe caber en -2048..2047 |
| `li rd, valor`    | una o dos instrucciones, ver abajo |

### Expansión de `li` y corrección de signo

`li rd, valor` carga una constante de 32 bits. Según el valor, se expande así:

1. Si el valor cabe en 12 bits con signo (-2048 a 2047): `addi rd, x0, valor`.
2. Si los 12 bits bajos son cero: `lui rd, valor >> 12`.
3. En el caso general, dos instrucciones: `lui rd, hi` y `addi rd, rd, lo`.

El caso general tiene una sutileza. `lui` deja los 20 bits altos en su lugar y los 12 bajos en cero, y `addi` suma un inmediato de 12 bits **con signo**. Si el bit 11 del valor deseado es 1, el inmediato de `addi` se interpreta como negativo, o sea resta 4096 de más. Para compensar hay que sumar 1 a la parte alta:

```
hi = (valor + 0x800) >> 12
lo = valor - (hi << 12)          # queda entre -2048 y 2047
```

Sumar `0x800` antes de desplazar equivale a redondear al múltiplo de 4096 más cercano, y así `lo` siempre cabe con signo en 12 bits.

**Ejemplo completo: `li x4, 0x04C11DB7`** (el polinomio del LFSR de `game.s`).

1. El valor no cabe en 12 bits y sus 12 bits bajos (`0xDB7`) no son cero, así que se usa el caso general.
2. El bit 11 de `0xDB7` es 1 (`0xDB7 = 1101 1011 0111`), así que hace falta la corrección.
3. `valor + 0x800 = 0x04C11DB7 + 0x00000800 = 0x04C125B7`.
4. `hi = 0x04C125B7 >> 12 = 0x04C12`. Sin la corrección habría sido `0x04C11`.
5. `lo = 0x04C11DB7 - 0x04C12000 = -0x249 = -585`.
6. Resultado:

```
lui  x4, 0x04C12
addi x4, x4, -585
```

7. Verificación: `lui` deja `0x04C12000`, y `addi` le suma -585 (`-0x249`): `0x04C12000 - 0x249 = 0x04C11DB7`. ✓

Estas dos instrucciones aparecen en `sw/game.hex` como `04c12237` y `db720213`.

## 7. Instrucciones soportadas

Las instrucciones base de RV32I que el assembler codifica, listadas abajo. No hay `ecall`, `ebreak`, `fence` ni instrucciones de CSR. Los mnemónicos están en `assembler/isa.py`.

| Formato | Instrucciones                                                        |
|---------|----------------------------------------------------------------------|
| R       | `add`, `sub`, `slt`, `sltu`, `xor`, `or`, `and`                      |
| R (shift, requiere `--allow-shifts`) | `sll`, `srl`, `sra`                     |
| I (aritméticas) | `addi`, `slti`, `sltiu`, `xori`, `ori`, `andi`               |
| I (shift, requiere `--allow-shifts`) | `slli`, `srli`, `srai`                  |
| I (carga)       | `lb`, `lh`, `lw`, `lbu`, `lhu`                               |
| I (salto)       | `jalr`                                                       |
| S       | `sb`, `sh`, `sw`                                                     |
| B       | `beq`, `bne`, `blt`, `bge`, `bltu`, `bgeu`                           |
| U       | `lui`, `auipc`                                                       |
| J       | `jal`                                                                |

Más las pseudo-instrucciones de la sección 6.

**Las que usa `sw/game.s`:** `lui`, `addi`, `andi`, `xori`, `xor`, `add`, `sub`, `lw`, `sw`, `beq`, `bne`, `blt`, `bltu`, `jal`, `jalr`, y las pseudo-instrucciones `li`, `mv` y `j`. El juego no usa `slt`, `sltu`, `bge`, `bgeu`, cargas de byte o media palabra, `auipc` ni shifts. El programa completo ocupa 115 palabras de las 512 disponibles.

## 8. Validaciones y suite de tests

El assembler rechaza con un mensaje de error, indicando el número de línea, los casos siguientes: registro fuera de x0 a x15 o desconocido, shift sin `--allow-shifts`, mnemónico o directiva desconocidos, etiqueta o constante repetida o no definida, inmediato fuera de rango, número incorrecto de operandos, operando de memoria mal formado, salto a dirección impar o fuera de alcance, y programa de más de 512 palabras.

La suite se corre con `make test` y tiene **73 tests**, repartidos así:

| Archivo                          | Tests | Qué verifica                                                                                                  |
|----------------------------------|-------|---------------------------------------------------------------------------------------------------------------|
| `tests/test_golden.py`           | 3     | Ensambla `blink.s`, `7seg.s` y `buttons_leds.s` y compara palabra por palabra con los `.hex` originales.      |
| `tests/test_formats.py`          | 8     | Codificaciones calculadas a mano que los `.hex` de referencia no cubren: `sub`, `slt`, `blt`, `bge`, `bltu`, `bgeu`, `jalr`, `auipc`. |
| `tests/test_pseudo.py`           | 16    | Las once pseudo-instrucciones simples y cinco casos de `li`, incluida la corrección de signo (con el ejemplo de la sección 6). |
| `tests/test_directives.py`       | 10    | `.equ` (hex, binario, sensibilidad a mayúsculas), `.word` (incluida una etiqueta hacia adelante), directivas ignoradas y mayúsculas. |
| `tests/test_defines.py`          | 3     | `-D` pisa el `.equ`, `-D` sin `.equ` en el archivo, y valor no numérico es error.                              |
| `tests/test_validation.py`       | 28    | Todas las validaciones del párrafo anterior, con casos límite en los rangos.                                   |
| `tests/test_roundtrip.py`        | 5     | Ensamblar, desensamblar con `assembler/disasm.py` y volver a ensamblar da lo mismo, para todas las instrucciones y para los tres ejemplos. Detecta errores de codificación que la comparación con archivos de referencia no ve. |
| **Total**                        | **73**|                                                                                                               |

## 9. Ejemplo completo de traducción: `sw x9, OFF_LEDS(x2)`

Con la constante `.equ OFF_LEDS, 4` de `sw/game.s`, la línea

```
sw   x9, OFF_LEDS(x2)
```

guarda el registro `x9` en la dirección `x2 + 4`. Como `x2` vale `0x8000_0000` (la base de periféricos), la **dirección efectiva es `0x8000_0004`**, que es el registro LEDS.

`sw` es de formato **S**. Su codificación, de izquierda a derecha, es:

```
 31        25 24  20 19  15 14  12 11       7 6      0
+------------+------+------+------+----------+--------+
| imm[11:5]  | rs2  | rs1  |funct3| imm[4:0] | opcode |
+------------+------+------+------+----------+--------+
```

El inmediato de 12 bits va partido en dos trozos, de modo que `rs1`, `rs2` y `funct3` quedan en la misma posición que en otros formatos.

Campo por campo:

| Campo       | Bits    | Valor                    | Binario   |
|-------------|---------|--------------------------|-----------|
| `imm[11:5]` | 31 a 25 | `4 = 0b000000000100`, bits 11 a 5 | `0000000` |
| `rs2`       | 24 a 20 | `x9`, el dato a guardar  | `01001`   |
| `rs1`       | 19 a 15 | `x2`, la base            | `00010`   |
| `funct3`    | 14 a 12 | `sw` (palabra)           | `010`     |
| `imm[4:0]`  | 11 a 7  | `4`, bits 4 a 0          | `00100`   |
| `opcode`    | 6 a 0   | store                    | `0100011` |

Concatenando de izquierda a derecha:

```
0000000 01001 00010 010 00100 0100011
```

Agrupado de a 4 bits:

```
0000 0000 1001 0001 0010 0010 0010 0011
 0    0    9    1    2    2    2    3
```

El resultado es **`0x00912223`**.

Esto se verificó contra el archivo real, que contiene la palabra en la línea 18 (la instrucción número 17, contando desde 0):

```
$ grep -n "00912223" sw/game.hex
18:00912223
```

Es la escritura a LEDS que hace `round_begin` justo antes de encender los cuatro LEDs.
