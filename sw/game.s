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
#     |  t0 <- CYCLES   (la marca es en ciclos, no en décimas)|
#     v                                                       |
#   WAIT_PRESS                                                |
#     |  polling de BTN; el LFSR avanza en cada vuelta        |
#     v                                                       |
#   ¿máscara leída == máscara objetivo?                       |
#     |                         |                             |
#    sí                        no                             |
#     v                         v                             |
#   HIT                       MISS                            |
#     |  t = cyc2tenths(        |  display "EE", LEDs off     |
#     |        CYCLES - t0)     |  espera ERROR_TENTHS -------+
#     |  suma += t, aciertos++  |                             |
#     |  display = BCD(t)       |                             |
#     |  espera MOSTRAR_TENTHS  |                             |
#     v                                                        |
#   ¿aciertos == RONDAS? -- no ---------------------------------+
#     |
#    sí
#     v
#   FINISH
#        display "AA" PROMEDIO_TENTHS décimas, luego BCD(suma/RONDAS),
#        LEDs parpadeando. Una pulsación vuelve a INIT.
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
# 8. El promedio se calcula con una división genérica por RONDAS, no con un
#    divisor fijo. La evaluación pide cambiar una constante del juego y volver
#    a demostrar: con un /10 clavado el promedio queda mal apenas RONDAS deja
#    de valer 10.
#
#
# BASE DE TIEMPO -- por qué se mide en ciclos
# -------------------------------------------
# El SoC expone un solo contador: CYCLES, libre, de 32 bits, +1 por ciclo de
# reloj a 25 MHz. Toda la conversión a décimas se hace acá en software.
#
# Antes había además un contador libre de décimas y se medía leyéndolo. Eso
# tiene un error sistemático que no se puede corregir desde el software: un
# contador libre no arranca cuando uno lo lee, así que la marca inicial cae en
# una fase arbitraria dentro de la décima en curso. Una misma duración real se
# lee a veces como N y a veces como N+1, y esa décima de incertidumbre no se
# promedia: está en cada medición y en cada espera. Una espera pedida de 30
# décimas podía durar 2,9 s, lo que incumple el "al menos tres segundos" del
# enunciado.
#
# Midiendo en ciclos el error de cuantización pasa a ser un ciclo, 40 ns, seis
# órdenes de magnitud por debajo de la décima que se muestra. Las esperas se
# convierten a ciclos ANTES de arrancar, así que una espera de 30 décimas dura
# 3,0 s o un pelo más, nunca menos.
#
# Como la base de tiempo ahora vive en software, bajarla para simulación es
# cambiar una constante al ensamblar:
#
#     python3 assembler/asm.py sw/game.s -o sw/game_sim.hex -D CYCLES_PER_TENTH=2500
#
# La opción -D del assembler pisa el .equ del archivo, así que no hace falta
# una segunda copia del programa que se pueda desincronizar de esta.
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
#   x1        ra de nivel 1: show_bcd, wait_tenths
#   x2        base de periféricos 0x80000000      <- vive todo el programa
#   x3        estado del LFSR                     <- vive todo el programa
#   x4        POLY                                <- vive todo el programa
#   x5        aciertos (0..RONDAS)                <- vive todo el programa
#   x6        suma acumulada en décimas           <- vive todo el programa
#   x7        máscara del LED objetivo            <- vive la ronda
#             (en FINISH se reusa como estado del parpadeo)
#   x8        t0 de la ronda, EN CICLOS           <- vive la ronda
#   x9-x14    temporales
#   x15       ra de nivel 2: div, cyc2tenths
#
# NINGUNA subrutina escribe x2-x8. Eso es lo que permite que x3 (LFSR), x5
# (aciertos), x6 (suma), x7 (objetivo) y x8 (t0) sobrevivan a las llamadas sin
# guardarlos en ningún lado.
#
# NO SE USA STACK. Las subrutinas no son recursivas, así que en vez de
# guardar ra en memoria se usa un registro de enlace distinto por nivel:
# show_bcd y wait_tenths retornan por x1, div y cyc2tenths por x15. Como
# show_bcd llama a div, show_bcd pisa x15: es legal porque show_bcd solo se
# llama desde el nivel 0. Cero memoria, cero sp.
#
# =============================================================================


# --- Constantes del juego (esto es lo que piden cambiar en la evaluación) ---
.equ RONDAS,         10      # aciertos necesarios para terminar
.equ ESPERA_TENTHS,  30      # 3,0 s con los cuatro LEDs encendidos
.equ MOSTRAR_TENTHS, 12      # 1,2 s mostrando el tiempo de reacción
.equ ERROR_TENTHS,   10      # 1,0 s mostrando "EE"
.equ PROMEDIO_TENTHS, 10     # 1,0 s mostrando "AA" antes del promedio
.equ PARPADEO_TENTHS, 5      # medio período del parpadeo final, 0,5 s
.equ MAX_TENTHS,     99      # saturación: el display son dos dígitos

# --- Base de tiempo ---
# El assembler no evalúa expresiones, así que CYCLES_PER_TENTH va como
# literal ya calculado. SI SE CAMBIA CLK_HZ HAY QUE CAMBIAR LOS DOS:
# CYCLES_PER_TENTH tiene que quedar siempre igual a CLK_HZ / 10.
.equ CLK_HZ,           25000000
.equ CYCLES_PER_TENTH,  2500000

# --- Periféricos (ver docs/memory_map.md) ---
.equ PERIPH_HI,   0x80000    # para el lui: base = 0x80000000
.equ OFF_DISP,    0          # W  [7:0] dos dígitos, decodificados a HEX
.equ OFF_LEDS,    4          # W  [3:0]
.equ OFF_BTN,     8          # R  [3:0] con debounce
.equ OFF_CYCLES,  12         # R  [31:0] contador libre a 25 MHz

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
    lw   x8, OFF_CYCLES(x2)        # t0 en ciclos: unos 3 ciclos después de
                                   # encender el LED, o sea 120 ns de sesgo
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
    lw   x9, OFF_CYCLES(x2)
    sub  x10, x9, x8                 # Δ en ciclos, resta modular de 32 bits
    jal  x15, cyc2tenths             # a0 = décimas, truncado y saturado

    add  x6, x6, x10                 # suma += t
    addi x5, x5, 1                    # aciertos++

    jal  x1, show_bcd                 # a0 sigue siendo t

    li   x10, MOSTRAR_TENTHS
    jal  x1, wait_tenths

    li   x9, RONDAS
    bne  x5, x9, round_begin
    # cae a finish


# =============================================================================
# FINISH -- promedio de las RONDAS rondas
# =============================================================================
finish:
    li   x9, PAT_AVG
    sw   x9, OFF_DISP(x2)

    li   x10, PROMEDIO_TENTHS
    jal  x1, wait_tenths

    mv   x10, x6                      # a0 = suma en décimas
    li   x12, RONDAS                   # divisor = la constante del juego
    jal  x15, div                       # a0 = promedio en décimas
    jal  x1, show_bcd

    li   x7, 0                          # estado del parpadeo de los LEDs.
                                        # Va en x7 y no en un temporal porque
                                        # wait_tenths pisa x9-x14.
finish_blink:
    xori x7, x7, ALL_LEDS               # alterna entre 0x0 y 0xF
    sw   x7, OFF_LEDS(x2)

    li   x10, PARPADEO_TENTHS
    jal  x1, wait_tenths

    lw   x9, OFF_BTN(x2)
    beq  x9, x0, finish_blink
    j    _start                          # una pulsación vuelve a INIT


# =============================================================================
# SUBRUTINAS
#
# Ninguna de estas escribe x2-x8. Ver el mapa de registros de la cabecera.
# =============================================================================

# -----------------------------------------------------------------------------
# div -- división entera sin signo por resta repetida. Retorna por x15.
#
#   entrada:  a0 = dividendo, x12 = divisor
#   salida:   a0 = cociente, a1 = resto
#   destruye: x9
#
# Sin extensión M ni shifts. Genérica a propósito: la usa show_bcd con
# divisor 10 y finish con divisor RONDAS, que es una constante que la
# evaluación puede pedir cambiar.
#
# La comparación es bltu, sin signo: el dividendo puede ser cualquier patrón
# de 32 bits y un bit 31 encendido no debe leerse como negativo.
#
# Un divisor 0 devuelve cociente 0 y resto = dividendo en vez de colgar la
# placa en un loop infinito.
# -----------------------------------------------------------------------------
div:
    li   x9, 0                # cociente
    beq  x12, x0, div_done     # divisor 0: salida temprana, sin loop
div_loop:
    bltu x10, x12, div_done
    sub  x10, x10, x12
    addi x9, x9, 1
    j    div_loop
div_done:
    mv   x11, x10              # resto
    mv   x10, x9                # cociente
    jalr x0, 0(x15)


# -----------------------------------------------------------------------------
# cyc2tenths -- convierte ciclos a décimas. Retorna por x15.
#
#   entrada:  a0 = duración en ciclos
#   salida:   a0 = duración en décimas, truncada hacia abajo y saturada
#             a MAX_TENTHS
#   destruye: x9, x12, x13
#
# Resta repetida de CYCLES_PER_TENTH, con el loop cortado también por
# MAX_TENTHS. Ese corte hace dos cosas de una: la saturación sale gratis y el
# loop da como mucho MAX_TENTHS vueltas por más que el jugador se demore un
# minuto en apretar.
#
# bltu porque la resta CYCLES - t0 es modular y puede tener el bit 31 en 1.
# -----------------------------------------------------------------------------
cyc2tenths:
    li   x9, 0                 # décimas contadas
    li   x12, CYCLES_PER_TENTH
    li   x13, MAX_TENTHS
c2t_loop:
    beq  x9, x13, c2t_done      # ya saturó, no tiene sentido seguir restando
    bltu x10, x12, c2t_done     # queda menos de una décima: truncar
    sub  x10, x10, x12
    addi x9, x9, 1
    j    c2t_loop
c2t_done:
    mv   x10, x9
    jalr x0, 0(x15)


# -----------------------------------------------------------------------------
# show_bcd -- muestra un valor 0..99 como dos dígitos decimales. Retorna por x1.
#
#   entrada:  a0 = valor 0..99
#   destruye: x9, x10, x11, x12, x15
#
# El display decodifica HEX por hardware, así que hay que empaquetar BCD:
# escribir 37 decimal (0x25) mostraría "25". Hay que escribir 0x37.
#
#   decenas, unidades <- div(a0, 10)
#   byte <- decenas*16 + unidades
#
# El *16 sin shift son cuatro duplicaciones encadenadas.
# -----------------------------------------------------------------------------
show_bcd:
    li   x12, 10
    jal  x15, div               # a0 = decenas, a1 = unidades
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
#   destruye: x9, x11, x12, x13, x14
#
# Primero convierte las décimas a ciclos sumando CYCLES_PER_TENTH N veces:
# no hay multiplicador y la extensión M no existe en este core. N acá vale
# como mucho unas decenas, así que el loop es despreciable frente a la espera.
#
# Después toma una marca de CYCLES y espera hasta que la diferencia alcance el
# total. La resta es modular, así que funciona aun si el contador da la vuelta,
# y la comparación es bltu porque esa diferencia no tiene signo.
#
# Cuantización: un ciclo, 40 ns. La espera siempre sale igual o un pelo más
# larga que la pedida, nunca más corta.
# -----------------------------------------------------------------------------
wait_tenths:
    li   x11, 0                   # total en ciclos
    li   x12, CYCLES_PER_TENTH
    mv   x13, x10                  # décimas que faltan por acumular
wt_mul_loop:
    beq  x13, x0, wt_mul_done
    add  x11, x11, x12
    addi x13, x13, -1
    j    wt_mul_loop
wt_mul_done:

    lw   x9, OFF_CYCLES(x2)        # marca inicial
wt_wait_loop:
    lw   x13, OFF_CYCLES(x2)        # marca actual
    sub  x14, x13, x9
    bltu x14, x11, wt_wait_loop
    jalr x0, 0(x1)
