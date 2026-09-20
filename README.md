# Juego de reflejos sobre Pochoco SoC y Espino Core

![Arquitectura del Pochoco SoC](pochoco_soc.svg)

## Qué es este proyecto

Es un juego de reflejos que corre sobre un procesador propio, sin sistema operativo, en la FPGA de la Go Board (iCE40 HX1K). El programa está escrito en assembly RV32E (`sw/game.s`), se traduce con un assembler hecho por el grupo en Python (`assembler/`) y se ejecuta en el Espino Core, un procesador de 32 bits dentro del Pochoco SoC.

El proyecto parte del repositorio [nic0villegasc/pochoco_soc](https://github.com/nic0villegasc/pochoco_soc), que aporta el core, la RAM, los periféricos y el flujo de síntesis. Sobre esa base se agregó:

- el juego (`sw/game.s`) y su medición de tiempo en ciclos de reloj,
- el assembler propio, que reemplaza al assembler externo prohibido por el enunciado,
- un sincronizador de botones y un debounce parametrizable,
- un contador de ciclos como única base de tiempo del SoC,
- testbenches que verifican el juego completo, incluida la medición.

## Cómo se juega

1. Al encender, el display muestra `00` y los LEDs están apagados. Se aprieta cualquier botón para comenzar. El instante de esa pulsación siembra el generador pseudoaleatorio.
2. En cada ronda se encienden los cuatro LEDs por 3 segundos, y el display muestra el número de ronda.
3. Después queda encendido un solo LED, elegido al azar. Hay que apretar lo antes posible el botón que corresponde a ese LED.
4. Si es el correcto, el display muestra el tiempo de reacción en décimas de segundo. Si es incorrecto, o si se aprietan dos botones a la vez, el display muestra `EE` y la ronda se reinicia completa, sin perder los aciertos acumulados.
5. Al completar `RONDAS` aciertos (10 por defecto), el display muestra `AA` y luego el promedio, con los LEDs parpadeando. Una pulsación vuelve a la pantalla de inicio.

Los tiempos se muestran con dos dígitos, saturados en 99 décimas.

## Estructura del repositorio

```
.
├── Makefile           síntesis, programación, ensamblado y verificación
├── goboard.pcf        asignación de pines de la Go Board
├── pochoco_soc.svg    diagrama de la arquitectura
├── rtl/               Verilog: SoC, periféricos y Espino Core (rtl/espino_core/)
│   ├── game_top.v     top de la síntesis, con los pines de la placa
│   ├── pochoco_soc.v  conecta core, RAM y periféricos
│   ├── pochoco_periph.v  DISP, LEDS, BTN y CYCLES
│   └── debounce.v     filtro de rebote de los botones
├── sw/                programas en assembly y sus .hex
│   ├── game.s         el juego
│   ├── game.hex       firmware del juego, versionado
│   └── blink, 7seg, buttons_leds   ejemplos originales del SoC
├── assembler/         assembler propio (Python 3)
│   ├── asm.py         línea de comandos
│   └── tests/         73 tests
├── tb/                testbenches de Icarus Verilog
└── docs/
    ├── memory_map.md  mapa de memoria y periféricos
    └── assembler.md   assembler: uso, sintaxis, codificación y tests
```

## Herramientas

Solo se necesitan dos cosas:

- **[oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build)**, que trae `yosys`, `nextpnr-ice40`, `icepack`, `iceprog` e `iverilog`.
- **Python 3**, sin librerías adicionales.

No se usa ningún assembler ni toolchain RISC-V externo.

## Sintetizar y programar la placa

Con la Go Board conectada por USB, desde la raíz del repositorio:

```bash
make
```

Es equivalente a `make prog` y ejecuta los cuatro pasos en orden, saltándose los que ya están al día. Cada paso se puede correr por separado:

| Paso | Qué hace                    | Comando exacto                                                                                                              |
|------|-----------------------------|-----------------------------------------------------------------------------------------------------------------------------|
| 1    | Síntesis (Yosys)            | `yosys -p "read_verilog ./rtl/*.v ./rtl/**/*.v; synth_ice40 -top game_top -json game_top.json; stat"`                       |
| 2    | Place and route (nextpnr)   | `nextpnr-ice40 --hx1k --package vq100 --freq 25 --json game_top.json --pcf goboard.pcf --asc game_top.asc`                  |
| 3    | Bitstream (icepack)         | `icepack game_top.asc game_top.bin`                                                                                         |
| 4    | Programar la placa (iceprog)| `iceprog game_top.bin`                                                                                                      |

Con `make` cada paso también tiene su nombre de objetivo: `make game_top.json`, `make game_top.asc`, `make game_top.bin` y `make prog`. En el paso 1, `make` reemplaza los comodines por la lista completa de archivos de `rtl/`.

**`sw/game.hex` es prerrequisito de la síntesis.** El módulo de RAM carga su contenido inicial con `$readmemh`, y Yosys lo resuelve al sintetizar: el programa queda horneado dentro del bitstream. Si se cambia `game.s` y no se vuelve a sintetizar, la placa sigue corriendo el código anterior. Por eso el `Makefile` declara `sw/game.hex` como prerrequisito de `game_top.json`, y un `make` después de editar `game.s` regenera el `.hex` y todo lo que depende de él.

## Regenerar `game.hex` desde `game.s`

```bash
make asm
```

Es equivalente a este comando, que se puede correr a mano:

```bash
python3 assembler/asm.py sw/game.s -o sw/game.hex
```

`make asm-all` regenera además los `.hex` de los tres ejemplos de `sw/`.

### Constantes del juego

Están al inicio de `sw/game.s` como `.equ` y se pueden cambiar:

| Constante          | Por defecto | Qué controla                                                     |
|--------------------|-------------|------------------------------------------------------------------|
| `RONDAS`           | 10          | Aciertos necesarios para terminar la partida                     |
| `ESPERA_TENTHS`    | 30          | Espera con los cuatro LEDs encendidos, en décimas (3,0 s)        |
| `MOSTRAR_TENTHS`   | 12          | Tiempo que se muestra el resultado de una ronda (1,2 s)          |
| `ERROR_TENTHS`     | 10          | Tiempo que se muestra `EE` tras un error (1,0 s)                 |
| `PROMEDIO_TENTHS`  | 10          | Tiempo que se muestra `AA` antes del promedio (1,0 s)            |
| `PARPADEO_TENTHS`  | 5           | Medio período del parpadeo final de los LEDs (0,5 s)             |
| `MAX_TENTHS`       | 99          | Saturación del tiempo de reacción (el display tiene dos dígitos) |
| `CYCLES_PER_TENTH` | 2500000     | Ciclos de reloj por décima de segundo                            |
| `CLK_HZ`           | 25000000    | Frecuencia del reloj, solo informativa                           |

`CYCLES_PER_TENTH` debe valer siempre `CLK_HZ / 10`, porque el assembler no evalúa expresiones y ambas van como literales. Si se cambia la frecuencia hay que cambiar las dos.

### Fijar una constante sin editar el archivo

La opción `-D` del assembler pisa el `.equ` del mismo nombre:

```bash
python3 assembler/asm.py sw/game.s -o sw/game.hex -D RONDAS=5 -D ESPERA_TENTHS=20
```

Cambiar `RONDAS` cambia también el divisor con que se calcula el promedio. La rutina de división de `game.s` recibe el divisor como parámetro, y el promedio se calcula como `suma / RONDAS`, no como una división por 10 fija. Con `RONDAS=5` el promedio se divide por 5 sin tocar nada más.

Después de regenerar `game.hex`, hay que volver a sintetizar (`make`) para que el cambio llegue a la placa.

## Verificar sin la placa

```bash
make check
```

Corre todo lo verificable por software:

- **73 tests del assembler** (`make test`): incluyen la comparación byte a byte con los `.hex` de los ejemplos originales y una prueba de ida y vuelta ensamblar, desensamblar y reensamblar.
- **Tres testbenches** (`make sim`), con Icarus Verilog:
  - `tb/game_top_tb.v` ejercita la cadena de botones (sincronizador y debounce) con rebotes inyectados, y revisa el contador CYCLES.
  - `tb/game_tb.v` recorre la máquina de estados completa: pantalla de inicio, las rondas, un error deliberado con su reintento, el patrón `AA`, el promedio, el parpadeo final y el reinicio.
  - La misma `tb/game_tb.v` corrida con `RONDAS=4`, como regresión del divisor del promedio.

Los testbenches verifican también la **medición**: inyectan un tiempo de reacción conocido, 12 décimas, esperando exactamente ese número de ciclos entre el encendido del LED y la pulsación, y exigen que el display muestre 12. Y verifican el **promedio**: en la corrida por defecto el promedio de diez rondas de 12 décimas debe ser 12, y en la corrida con `RONDAS=4` también, lo que fallaría si el divisor estuviera fijo en 10 (daría 48/10 = 4).

Para que las simulaciones corran en segundos y no en minutos, se usan `sw/game_sim.hex` y `sw/game_sim_r4.hex`, que son el mismo `game.s` ensamblado con `-D CYCLES_PER_TENTH=2500` (y `-D RONDAS=4` el segundo). El `Makefile` los genera solo y no se versionan.

La simulación necesita los modelos de celdas iCE40 de Yosys (`ice40/cells_sim.v`), porque el banco de registros instancia `SB_RAM40_4K`. Si `make sim` no los encuentra: `make sim CELLS_SIM=/ruta/a/ice40/cells_sim.v`.

## Base de tiempo

El SoC tiene un solo contador de tiempo: `CYCLES`, de 32 bits, que suma 1 por cada ciclo del reloj de 25 MHz. Todo el tiempo del juego (esperas y tiempo de reacción) se mide por diferencia de lecturas y se convierte a décimas en software, con `CYCLES_PER_TENTH = 2.500.000`. No hay un contador de décimas en hardware porque introducía un error de una décima y ocupaba lugar en la FPGA. Las razones completas, junto con el resto del mapa de memoria, están en [docs/memory_map.md](docs/memory_map.md).

## Documentación

- [docs/memory_map.md](docs/memory_map.md): espacio de direcciones, registros de periférico, camino de los botones, CYCLES y temporización.
- [docs/assembler.md](docs/assembler.md): uso del assembler, sintaxis, pseudo-instrucciones, instrucciones soportadas, tests y un ejemplo completo de traducción a código máquina.

## Uso de recursos

Medido con `nextpnr-ice40` a 25 MHz sobre la HX1K:

| Recurso        | Usado / Disponible | Porcentaje |
|----------------|--------------------|------------|
| `ICESTORM_LC`  | 1139 / 1280        | 88 %       |
| `ICESTORM_RAM` | 12 / 16            | 75 %       |
| `SB_IO`        | 27 / 72            | 37 %       |
| Fmax           | 45,3 MHz           | PASS a 25 MHz |

Antes de sacar el contador de décimas del hardware, el diseño usaba 1210 / 1280 LCs (94 %).

## Nota sobre el core

El Espino Core implementa [RV32E](https://docs.riscv.org/reference/isa/v20260120/unpriv/rv32.html) con una particularidad: las instrucciones de desplazamiento (`sll`, `srl`, `sra` y sus versiones con inmediato) se decodifican bien, pero la ALU las ejecuta como `add` para ahorrar LUTs. El assembler las rechaza por defecto, y `game.s` desplaza sumando un registro consigo mismo.
