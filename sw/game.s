# =============================================================================
# game.s -- Juego de reflejos para Pochoco SoC / Espino Core (RV32E)
#
# Proyecto 2 -- Arquitectura de Computadores 2026-2
#
# ESTADO: completo. Diseño, constantes e instrucciones.
#
# Contratos de los que depende:
#   docs/memory_map.md   -- qué dirección hace qué
#   docs/assembler.md    -- qué instrucciones y sintaxis existen
# =============================================================================
#
# QUÉ HACE
# --------
# En cada ronda se encienden los cuatro LEDs por 3 segundos, después se
# enciende uno solo elegido pseudoaleatoriamente, y el jugador debe apretar
# el botón correspondiente lo más rápido posible. Se muestra el tiempo de
# reacción en décimas de segundo. Tras diez aciertos se muestra el promedio.
# Una pulsación incorrecta muestra error y reinicia la ronda, sin perder los
# aciertos acumulados.
#
#
# MÁQUINA DE ESTADOS
# ------------------
#
#   INIT
#     |  sp no se usa, base de periféricos, LFSR=1, aciertos=0, suma=0
#     v
#   START_SCREEN
#     |  display "00", LEDs apagados, espera una pulsación
#     |  al apretar: SEMILLA <- CYCLES  (única fuente de entropía inicial)
#     |  espera a que suelte
#     v
#   ROUND_BEGIN  <-------------------------------------------+
#     |  LEDS = 0xF, display = número de ronda                |
#     |  espera ESPERA_TENTHS décimas                         |
#     v                                                       |
#   ARM                                                       |
#     |  espera BTN == 0 (todos sueltos)                      |
#     |  objetivo <- 2 bits bajos del LFSR                    |
#     |  LEDS = solo el objetivo                              |
#     |  t_start <- TENTHS                                    |
#     v                                                       |
#   WAIT_PRESS                                                |
#     |  polling de BTN; el LFSR avanza en cada vuelta        |
#     v                                                       |
#   ¿máscara leída == máscara objetivo?                       |
#     |                         |                             |
#    sí                        no                             |
#     v                         v                             |
#   HIT                       MISS                            |
#     |  t = TENTHS - t_start    |  display "EE", LEDs off    |
#     |  satura a MAX_TENTHS     |  espera ERROR_TENTHS ------+
#     |  suma += t, aciertos++   |                             |
#     |  display = BCD(t)        |                             |
#     |  espera MOSTRAR_TENTHS   |                             |
#     v                                                        |
#   ¿aciertos == RONDAS? -- no ---------------------------------+
#     |
#    sí
#     v
#   FINISH
#        display "AA" 1 s, luego BCD(suma/10), LEDs parpadeando
#        una pulsación vuelve a INIT
#
#
# DECISIONES DE DISEÑO
# --------------------
# 1. Hay una pantalla de inicio. La ronda 1 necesita un objetivo antes de que
#    el jugador toque nada, así que la semilla tiene que venir de una acción
#    humana o el LED de la primera ronda sería idéntico en cada encendido de
#    la placa. La pulsación de inicio muestrea CYCLES a 25 MHz: ~16 bits de
#    entropía real.
#
# 2. Un error reinicia la ronda COMPLETA, incluidos los 3 segundos. Es la
#    lectura literal del enunciado ("reiniciar la ronda actual"). El contador
#    de aciertos no se toca.
#
# 3. El objetivo se re-sortea tras un error, para que repetir la ronda no sea
#    gratis.
#
# 4. Apretar dos botones a la vez es error: se compara la máscara completa de
#    4 bits, no "¿está encendido el bit correcto?".
#
# 5. Durante los 3 segundos el display muestra el número de ronda. Da feedback
#    de progreso y en la demo se ve de un vistazo que van 7 de 10.
#
# 6. El promedio se anuncia con "AA" y con los LEDs parpadeando, porque si no
#    no hay forma de distinguir un promedio de 04 del tiempo de la última
#    ronda.
#
# 7. El display nunca queda en blanco: el decodificador de hardware mapea los
#    16 valores posibles de cada nibble a un carácter. Escribir 0x00 muestra
#    "00", no apagado.
#
#
# PSEUDOALEATORIEDAD -- LFSR de Galois corriendo a la izquierda
# ------------------------------------------------------------
# El core tiene los shifts deshabilitados (ejecutan como ADD), así que un
# LFSR clásico que extrae bits no sirve. Un LFSR de Galois hacia la izquierda
# no necesita extraer nada:
#
#     msb = (x < 0)            blt x3, x0, ...   el bit 31 ES el de signo
#     x   = x + x              add x3, x3, x3    shift left de 1 bit
#     si msb: x = x ^ POLY     xor con una constante fija
#
# Tres instrucciones y una constante en registro. POLY = 0x04C11DB7 es un
# polinomio primitivo de grado 32, o sea período 2^32-1 estados.
#
# EL ESTADO NO SE REINICIA NUNCA. No hay "semilla por ronda". La semilla se
# fija una sola vez en START_SCREEN; de ahí en adelante el estado solo avanza.
# Cuando toca armar una ronda se leen los 2 bits bajos del estado que haya en
# ese momento. El número de ronda NO entra en el cálculo del objetivo.
#
# El paso del LFSR va DENTRO del loop de polling, no afuera: el loop son ~10
# ciclos, o sea una vuelta cada 0,4 us. Una reacción de 300 ms son ~750.000
# pasos. Para repetir una partida habría que repetir cada tiempo de reacción
# con precisión de microsegundos.
#
# CUIDADO: el estado cero es un punto fijo. Si la semilla sale 0, forzar a 1.
#
#
# MAPA DE REGISTROS (RV32E: solo x0-x15)
# --------------------------------------
#   x0        cero
#   x1        ra de show_bcd y wait_tenths
#   x2        base de periféricos 0x80000000      <- vive todo el programa
#   x3        estado del LFSR                     <- vive todo el programa
#   x4        POLY                                <- vive todo el programa
#   x5        aciertos (0..RONDAS)                <- vive todo el programa
#   x6        suma acumulada en décimas           <- vive todo el programa
#   x7        máscara del LED objetivo            <- vive la ronda
#   x8        t_start de la ronda                 <- vive la ronda
#   x9-x14    temporales
#   x15       ra de div10  (nivel de anidamiento interno)
#
# NO SE USA STACK. Las subrutinas no son recursivas, así que en vez de
# guardar ra en memoria se usa un registro de enlace distinto por nivel:
# show_bcd retorna por x1, div10 retorna por x15. Cero memoria, cero sp.
#
# =============================================================================


# --- Constantes del juego (esto es lo que piden cambiar en la evaluación) ---
.equ RONDAS,         10      # aciertos necesarios para terminar
.equ ESPERA_TENTHS,  30      # 3,0 s con los cuatro LEDs encendidos
.equ MOSTRAR_TENTHS, 12      # 1,2 s mostrando el tiempo de reacción
.equ ERROR_TENTHS,   10      # 1,0 s mostrando "EE"
.equ MAX_TENTHS,     99      # saturación: el display son dos dígitos

# --- Periféricos (ver docs/memory_map.md) ---
.equ PERIPH_HI,   0x80000    # para el lui: base = 0x80000000
.equ OFF_DISP,    0          # W  [7:0] dos dígitos, decodificados a HEX
.equ OFF_LEDS,    4          # W  [3:0]
.equ OFF_BTN,     8          # R  [3:0] con debounce
.equ OFF_CYCLES,  12         # R  [31:0] contador libre a 25 MHz
.equ OFF_TENTHS,  16         # R  [31:0] contador libre a 10 Hz

# --- Patrones de display ---
.equ PAT_ERROR,   0xEE       # "EE"
.equ PAT_AVG,     0xAA       # "AA"
.equ PAT_START,   0x00       # "00"

# --- LFSR ---
# POLY = 0x04C11DB7. Ojo al ensamblarlo: los 12 bits bajos son 0xDB7, con el
# bit 11 encendido, así que li necesita la corrección de signo:
#     lui  x4, 0x04C12        (no 0x04C11)
#     addi x4, x4, -585
.equ LFSR_POLY,   0x04C11DB7

.equ ALL_LEDS,    0xF


.section .text
.global _start

# =============================================================================
# INIT
# =============================================================================
_start:
    lui  x2, PERIPH_HI      # x2 = 0x80000000  base de periféricos
    li   x4, LFSR_POLY      # x4 = POLY (li hace la corrección de signo)
    li   x3, 1               # x3 = 1, semilla provisoria; se resiembra abajo
    li   x5, 0                # aciertos = 0
    li   x6, 0                # suma = 0
    # cae a start_screen


# =============================================================================
# START_SCREEN -- espera la pulsación que siembra el LFSR
# =============================================================================
start_screen:
    li   x9, PAT_START
    sw   x9, OFF_DISP(x2)
    sw   x0, OFF_LEDS(x2)

ss_wait_press:
    lw   x9, OFF_BTN(x2)
    beq  x9, x0, ss_wait_press

    lw   x3, OFF_CYCLES(x2)      # semilla real: ciclos en el instante del toque
    bne  x3, x0, ss_wait_release
    li   x3, 1                    # cero es punto fijo del LFSR

ss_wait_release:
    lw   x9, OFF_BTN(x2)          # esperar a que suelte, si no mediría 0,0 s
    bne  x9, x0, ss_wait_release
    # cae a round_begin


# =============================================================================
# ROUND_BEGIN -- cuatro LEDs encendidos, espera de 3 segundos
# =============================================================================
round_begin:
    li   x9, ALL_LEDS
    sw   x9, OFF_LEDS(x2)

    addi x10, x5, 1                # a0 = número de ronda = aciertos+1
    jal  x1, show_bcd

    li   x10, ESPERA_TENTHS
    jal  x1, wait_tenths
    # cae a arm


# =============================================================================
# ARM -- elige objetivo, lo enciende y arranca la medición
# =============================================================================
arm:
arm_wait_release:
    lw   x9, OFF_BTN(x2)
    bne  x9, x0, arm_wait_release

    andi x9, x3, 3                 # índice 0..3: los 2 bits bajos del LFSR
    li   x7, 1
arm_shift_loop:                    # x7 <- x7 << x9, sin shifter: doblar x9 veces
    beq  x9, x0, arm_shift_done
    add  x7, x7, x7
    addi x9, x9, -1
    j    arm_shift_loop
arm_shift_done:
    sw   x7, OFF_LEDS(x2)          # enciende solo el LED objetivo
    lw   x8, OFF_TENTHS(x2)        # t_start
    # cae a wait_press


# =============================================================================
# WAIT_PRESS -- polling con el LFSR avanzando en cada vuelta
# =============================================================================
wait_press:
    lw   x9, OFF_BTN(x2)

    # paso del LFSR de Galois hacia la izquierda (sin shifter):
    blt  x3, x0, wp_feedback        # msb = bit de signo de x3
    add  x3, x3, x3                  # x3 <- x3 << 1
    j    wp_lfsr_done
wp_feedback:
    add  x3, x3, x3
    xor  x3, x3, x4                  # x3 <- x3 ^ POLY
wp_lfsr_done:

    beq  x9, x0, wait_press          # nada apretado, repetir
    beq  x9, x7, hit                 # máscara == objetivo
    # si no, cae a miss (máscara distinta: botón erróneo o varios a la vez)


# =============================================================================
# MISS -- pulsación incorrecta
# =============================================================================
miss:
    li   x9, PAT_ERROR
    sw   x9, OFF_DISP(x2)
    sw   x0, OFF_LEDS(x2)

    li   x10, ERROR_TENTHS
    jal  x1, wait_tenths
    j    round_begin                 # aciertos y suma NO se tocan


# =============================================================================
# HIT -- pulsación correcta
# =============================================================================
hit:
    lw   x9, OFF_TENTHS(x2)
    sub  x9, x9, x8                  # t = TENTHS - t_start, resta modular

    li   x11, MAX_TENTHS
    blt  x11, x9, hit_saturate        # si MAX_TENTHS < t, saturar
    j    hit_join
hit_saturate:
    li   x9, MAX_TENTHS
hit_join:

    add  x6, x6, x9                   # suma += t
    addi x5, x5, 1                     # aciertos++

    mv   x10, x9
    jal  x1, show_bcd

    li   x10, MOSTRAR_TENTHS
    jal  x1, wait_tenths

    li   x9, RONDAS
    bne  x5, x9, round_begin
    # cae a finish


# =============================================================================
# FINISH -- promedio de las diez rondas
# =============================================================================
finish:
    li   x9, PAT_AVG
    sw   x9, OFF_DISP(x2)

    li   x10, 10
    jal  x1, wait_tenths

    mv   x10, x6                      # a0 = suma
    jal  x15, div10                    # a0 = cociente = promedio en décimas
    jal  x1, show_bcd

    li   x12, 0                        # estado de parpadeo de LEDS
finish_blink:
    xori x12, x12, ALL_LEDS            # alterna entre 0x0 y 0xF
    sw   x12, OFF_LEDS(x2)

    li   x10, 5                         # medio período, 0,5 s
    jal  x1, wait_tenths

    lw   x9, OFF_BTN(x2)
    beq  x9, x0, finish_blink
    j    _start                          # una pulsación vuelve a INIT


# =============================================================================
# SUBRUTINAS
# =============================================================================

# -----------------------------------------------------------------------------
# div10 -- divide por 10 por resta repetida. Retorna por x15.
#
#   entrada:  a0 = dividendo  (0..990 en este juego)
#   salida:   a0 = cociente
#             a1 = resto
#
# Sin extensión M ni shifts. El cociente acá nunca pasa de 99, así que el
# loop hace como mucho 99 vueltas. Se usa dos veces: para el promedio
# (suma/10) y dentro de show_bcd (separar decenas de unidades).
# -----------------------------------------------------------------------------
div10:
    li   x9, 0                # cociente
    li   x12, 10
div10_loop:
    blt  x10, x12, div10_done
    sub  x10, x10, x12
    addi x9, x9, 1
    j    div10_loop
div10_done:
    mv   x11, x10              # resto
    mv   x10, x9                # cociente
    jalr x0, 0(x15)


# -----------------------------------------------------------------------------
# show_bcd -- muestra un valor 0..99 como dos dígitos decimales. Retorna por x1.
#
#   entrada:  a0 = valor 0..99
#
# El display decodifica HEX por hardware, así que hay que empaquetar BCD:
# escribir 37 decimal (0x25) mostraría "25". Hay que escribir 0x37.
#
#   decenas, unidades <- div10(a0)
#   byte <- decenas*16 + unidades
#
# El *16 sin shift son cuatro duplicaciones encadenadas.
# -----------------------------------------------------------------------------
show_bcd:
    jal  x15, div10             # a0 = decenas, a1 = unidades
    mv   x9, x10
    add  x9, x9, x9               # x2
    add  x9, x9, x9               # x4
    add  x9, x9, x9               # x8
    add  x9, x9, x9               # x16  (decenas << 4, sin shifter)
    add  x9, x9, x11               # + unidades
    sw   x9, OFF_DISP(x2)
    jalr x0, 0(x1)


# -----------------------------------------------------------------------------
# wait_tenths -- espera N décimas de segundo. Retorna por x1.
#
#   entrada:  a0 = número de décimas
#
# TENTHS es libre y no se resetea: se toma una marca y se espera hasta que la
# diferencia llegue a N. La resta modular de 32 bits funciona aun si el
# contador da la vuelta.
# -----------------------------------------------------------------------------
wait_tenths:
    lw   x9, OFF_TENTHS(x2)      # marca inicial
wait_tenths_loop:
    lw   x13, OFF_TENTHS(x2)      # marca actual
    sub  x14, x13, x9
    blt  x14, x10, wait_tenths_loop
    jalr x0, 0(x1)
