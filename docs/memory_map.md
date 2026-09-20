# Mapa de memoria del Pochoco SoC

Este documento es el contrato entre el hardware (`rtl/`) y el software (`sw/game.s`): dice qué dirección hace qué. Si el código y este documento discrepan, hay un error en uno de los dos y hay que corregirlo.

## Espacio de direcciones

El decodificador de `rtl/pochoco_soc.v` mira solo dos bits de la dirección de datos: el bit 31 distingue RAM de periféricos y el bit 16 distingue, dentro de los periféricos, el bloque de la placa del SPI.

| Base          | Tamaño        | Contenido                                      |
|---------------|---------------|------------------------------------------------|
| `0x0000_0000` | 512 palabras  | RAM unificada de instrucciones y datos (2 KiB) |
| `0x8000_0000` | 4 registros   | Periféricos de la placa (ver tabla siguiente)  |
| `0x8001_0000` | (sin instanciar) | Esclavo SPI                                 |

La RAM parte en la dirección 0, que es también la dirección de arranque del core (`BootAddr`). El programa completo, con sus constantes, tiene que caber en 512 palabras; el assembler lo verifica.

### Por qué el SPI no se instancia

El módulo `rtl/pochoco_spi_slave.v` viene con el repositorio original pero este proyecto no lo usa. Instanciarlo cuesta unos 86 LCs y la FPGA de la Go Board (iCE40 HX1K) tiene solo 1280, con el diseño ya cerca del límite (ver README, sección de recursos). Por eso `pochoco_soc.v` deja `spi_rdata` en cero y ata `o_SPI_MISO` a 1. El archivo queda intacto por si algún día hace falta, y los pines siguen conectados para no romper `goboard.pcf`.

## Registros de periférico

Las direcciones de esta tabla son offsets desde `0x8000_0000`.

| Offset | Nombre | Acceso | Bits     | Función                                   |
|--------|--------|--------|----------|-------------------------------------------|
| `0x00` | DISP   | W      | `[7:0]`  | Dos dígitos del display de 7 segmentos    |
| `0x04` | LEDS   | W      | `[3:0]`  | Los cuatro LEDs                           |
| `0x08` | BTN    | R      | `[3:0]`  | Los cuatro botones, ya filtrados          |
| `0x0C` | CYCLES | R      | `[31:0]` | Contador libre de ciclos de reloj         |

Cualquier otro offset lee cero, y una escritura a un registro de solo lectura o a un offset no listado se ignora.

### DISP

Los bits `[7:4]` controlan el dígito izquierdo y los bits `[3:0]` el derecho. Cada nibble pasa por un decodificador hexadecimal a 7 segmentos que cubre los 16 valores posibles, de `0` a `F`. Como consecuencia, el display nunca queda en blanco: escribir `0x00` muestra "00", no un display apagado.

El decodificador interpreta el nibble como número hexadecimal, no como decimal. Para mostrar el número 37 hay que escribir `0x37` (decenas en el nibble alto, unidades en el bajo), o sea empaquetar BCD. Escribir el decimal 37 (que es `0x25`) mostraría "25". En `sw/game.s` lo hace la subrutina `show_bcd`.

Los segmentos de la Go Board son activos en bajo. El decodificador de `pochoco_periph.v` entrega los segmentos en activo alto y la inversión la hace `pochoco_soc.v` justo antes de los pines.

### LEDS

El bit `k` de `[3:0]` enciende el LED `k`. Los bits superiores se ignoran.

### BTN

Los botones de la Go Board son activos en alto: leer 1 significa apretado. El valor que ve el software pasa por este camino:

```
pad asíncrono -> sincronizador de 2 flip-flops -> debounce -> registro BTN
```

**Sincronizador.** El pad del botón no está sincronizado con el reloj del SoC: una persona lo aprieta en cualquier instante. Si la señal cambia justo en el borde de reloj, no se cumple el tiempo de establecimiento (setup) del primer flip-flop y este puede quedar en un estado intermedio, ni 0 ni 1, durante un tiempo impredecible. Es la metaestabilidad. Si ese valor dudoso llegara directo a la lógica, distintas partes del circuito podrían interpretarlo de forma distinta. Con dos flip-flops en serie, el segundo solo muestrea la salida del primero un ciclo después, cuando casi con certeza ya se resolvió. Este problema no se ve nunca en simulación, porque en Verilog las señales cambian de forma ideal, pero sí puede aparecer en la placa, y por eso el sincronizador está aunque los testbenches pasen sin él.

**Debounce.** Un botón mecánico rebota: al apretarlo la señal oscila varios milisegundos antes de asentarse. El filtro (`rtl/debounce.v`) toma una muestra de cada botón cada `2^DebounceDivBits` ciclos. Con el valor por defecto de 15 bits son 32768 ciclos, o sea 1,31 ms a 25 MHz. El valor filtrado solo cambia tras `DebounceTicks` muestras consecutivas iguales, por defecto 3, lo que da del orden de 4 a 5 ms de retardo. Un rebote deja muestras mezcladas y no mueve la salida.

### CYCLES

Es la única base de tiempo del SoC: un contador libre de 32 bits, de solo lectura, que suma 1 en cada ciclo de reloj desde el reset. No se puede detener ni reiniciar por software.

El software siempre mide por diferencia: guarda una lectura inicial `t0`, más tarde lee `t1` y calcula `t1 - t0`. La resta modular de 32 bits da el resultado correcto aunque el contador haya dado la vuelta entre las dos lecturas, lo que ocurre cada `2^32 / 25 MHz`, o sea cada 171 segundos. Por eso las comparaciones de duración en `game.s` usan `bltu` (sin signo).

## Frecuencia de reloj y conversión a décimas

El reloj es el oscilador de 25 MHz de la Go Board (pin 15) y va directo al diseño, sin PLL. Una décima de segundo son

```
CYCLES_PER_TENTH = 25.000.000 / 10 = 2.500.000 ciclos
```

La conversión de ciclos a décimas la hace la subrutina `cyc2tenths` de `sw/game.s`, por restas repetidas de `CYCLES_PER_TENTH`.

## Por qué no hay un contador de décimas en hardware

Una versión anterior del diseño tenía, además de CYCLES, un contador de décimas en hardware, y el software medía leyéndolo. Se eliminó por dos motivos.

**(a) Corrección.** Un contador libre de décimas no arranca cuando el software lo lee: su fase es arbitraria. Al tomar la marca inicial, el contador está en un punto cualquiera de la décima en curso. La diferencia entre dos lecturas es entonces la cantidad de bordes de décima cruzados, no el tiempo transcurrido. Una misma duración real se lee a veces como N y a veces como N+1. Ese error de una décima no se promedia: está en cada medición y en cada espera. En particular, una espera pedida de 30 décimas podía durar solo 2,9 s, lo que incumple el "al menos tres segundos" del enunciado. Con CYCLES la marca se toma en el ciclo exacto y el error de cuantización baja a un ciclo, 40 ns.

**(b) Espacio.** El prescaler de 22 bits, el contador y el comparador contra 2.500.000 costaban unos 70 LCs. Al sacarlos, el diseño pasó de 1210/1280 a 1139/1280 LCs.

**Contrapartida.** La base de tiempo ya no es un parámetro del RTL, sino una constante de `game.s`. Para simular sin esperar minutos, los testbenches la bajan al ensamblar con `-D CYCLES_PER_TENTH=2500`, que hace la décima 1000 veces más corta. Ver `docs/assembler.md`, sección 2.

## Temporización de los accesos

Tanto la RAM como los periféricos tienen lectura registrada: el dato aparece un ciclo después de pedirlo. La unidad de carga y almacenamiento (LSU) lo absorbe levantando `busy` un ciclo, y detiene el pipeline mientras tanto. En la práctica un `lw` tarda 3 ciclos y el resto de las instrucciones, incluido `sw`, tarda 2.

## DISP y LEDS no se escriben de forma atómica

DISP y LEDS son dos registros distintos. Para cambiar ambos el software necesita dos instrucciones `sw`, y entre una y otra pasan 2 ciclos. Durante ese intervalo el hardware muestra un estado mezclado: el display ya cambió pero los LEDs no, o al revés. Ningún observador humano lo nota, pero un testbench que muestree ambos en el mismo instante sí. Por eso los testbenches no muestrean el segundo cambio, sino que lo esperan como un evento con un tiempo máximo. Por ejemplo, `miss` en `game.s` escribe DISP y recién en la instrucción siguiente apaga los LEDs.
