# gonzabot

[English](README.md) | **Español**

![license](https://img.shields.io/badge/license-MIT-blue) ![python](https://img.shields.io/badge/python-3%20stdlib%20only-green)

Asistente de IA para usuarios de un cluster HPC (Slurm + Spack), pensado para
encontrar errores de configuración, malos usos de recursos y pedidos
exagerados de recursos en scripts `sbatch` **antes** de que el job corra y
falle o desperdicie horas de cómputo.

Corre sobre un modelo local vía [vLLM](https://github.com/vllm-project/vllm)
— en producción con **GLM-4.5-Air** desde el 30/8/2026 (antes
Qwen2.5-72B-Instruct-AWQ, ver sección "Comparación de modelos" más abajo
para por qué migramos) — sin dependencias externas de Python más allá de
la librería estándar.

Desarrollado y usado en producción en el cluster HPC del IFIMAR (CONICET /
UNMDP, Argentina).

## Motivación

En un cluster HPC compartido es común perder horas de cómputo por errores
evitables: `--mem`/`--time` mal dimensionados, variables de entorno mal
resueltas dentro de un script, paralelismo mal configurado (`--ntasks` que no
matchea el paralelismo real del programa), rutas relativas que se rompen al
moverse a un directorio de trabajo temporal, etc. gonzabot conversa con el
usuario en lenguaje natural, entiende su script y su intención, y sugiere el
`sbatch` corregido — citando la razón del cambio.

## Resultados medidos

Casos reales de usuarios del cluster, comparando tiempo de ejecución antes y
después de aplicar la sugerencia de gonzabot (mismo nodo, mismos datos):

- LAMMPS (barrido de parámetro secuencial → job array): **~2.7x** más rápido.
- Quantum ESPRESSO/`ph.x` (fonones, `--ntasks` no escalado con `-nimage`):
  validado real, subir `-nimage` sin escalar `--ntasks` en proporción llegó
  a ser **44% más lento**, no más rápido (nimage 4 → 27.1 min, nimage 8,
  mismo `--ntasks` → 39.2 min).

Ejemplo real — le pedimos a gonzabot en vivo (sesión nueva, sin editar la
respuesta) cómo paralelizar un cálculo de fonones con `ph.x -nimage 4`.
Esto es lo que generó, tal cual, el 29/8/2026:

```diff
 #SBATCH --nodes=1
-#SBATCH --ntasks=16
+#SBATCH --ntasks=64
 #SBATCH --cpus-per-task=1

-mpirun -np 16 ph.x -nimage 4 -in input.in
+mpirun -np 64 --bind-to core --map-by core ph.x -nimage 4 -in input.in
```

(la línea `-` es la forma naive de pedirlo — mismo `--ntasks` que sin
`-nimage` — la `+` es la respuesta real de gonzabot: escala `--ntasks` a
64 para que cada una de las 4 imágenes tenga sus propios 16 procesos MPI,
en vez de repartir 16 procesos entre las 4 imágenes). Script completo real
en [`tutorial/ph_x_fonones_real.sbatch`](tutorial/ph_x_fonones_real.sbatch).

## Comparación de modelos

Evaluamos si un modelo distinto resolvía mejor el problema clásico de
"lost in the middle". Comparación sistemática entre Qwen2.5-72B-Instruct-AWQ
(el que estaba en producción hasta el 30/8) y GLM-4.5-Air, misma
infraestructura, mismas preguntas:

- Calidad/atención a reglas: GLM-4.5-Air ganó en la mayoría de los casos
  puntuales que probamos -- incluido un caso real donde diagnosticó
  correctamente un job fallado (`/diagnose`) que Qwen reportó como "sin
  errores" (falso negativo).
- Velocidad: Qwen2.5-72B es ~30% más rápido generando, en nuestro
  hardware (A100 80GB) -- el costo real de haber migrado.
- Limitación conocida, todavía abierta en producción: el comando
  `/branch` (genera 3 variantes de fix candidatas, las corre, compara
  resultados) no funciona de forma confiable con GLM-4.5-Air -- el
  modelo no siempre respeta el formato de diff estructurado que ese
  comando exige. Con Qwen2.5-72B sí funcionaba.

Con la calidad como criterio principal, **GLM-4.5-Air pasó a producción
el 30/8/2026**. El regression-testing posterior a la migración (probar
en vivo, con la infraestructura real, los casos que ya andaban bien con
Qwen) encontró y arregló 4 bugs nuevos específicos de GLM que no habían
aparecido en la comparación sistemática previa -- GROMACS invocado sin
`mpirun`, GPU pedida junto a un build de spack sin soporte CUDA, hash de
spack real sin la `/` inicial -- y de paso destapó una contradicción real
preexistente en la documentación de sitio (`context/spack.txt` decía dos
cosas distintas sobre si GROMACS resuelve sin hash). Ninguno es un bug
del LLM: todos viven en el post-procesador o en `context/`, ver
"Arquitectura" más abajo.

De paso, usar GLM-4.5-Air nos llevó a encontrar y reportar un bug real
de vLLM -- el contenido del razonamiento (`<think>...</think>`) a veces se
filtra sin separar hacia la respuesta visible en streaming sin tools, a
contextos largos. Reporte y repro standalone:
[vllm-project/vllm#29763 (comment)](https://github.com/vllm-project/vllm/issues/29763#issuecomment-5470158016)

## Arquitectura

- `gonzabot` — CLI interactivo en Python 3 puro (stdlib únicamente:
  `sqlite3` para persistir sesiones, `urllib` para hablar con el endpoint
  OpenAI-compatible de vLLM). Sin `pip install` necesario.
- `context/` — archivos de texto plano que se inyectan como contexto del
  cluster. Divididos por segmento temático (reglas transversales siempre
  cargadas + un archivo por familia de software -- dinámica molecular, DFT,
  física de partículas, GPU/CUDA, genómica, Python, etc.), cada uno con su
  propio trigger de palabras clave -- así una pregunta sobre una
  herramienta puntual no arrastra contexto irrelevante de las demás.
- Post-procesamiento determinístico (no depende del LLM) sobre el `sbatch`
  generado: detecta y corrige patrones frecuentes (heredocs mal citados,
  `cd $WORKDIR` inyectado sobre rutas relativas que ya funcionaban, `\$`
  espurios fuera de heredoc, `module load` con nombre de paquete ambiguo en
  Spack, separadores decorativos de comentario mal interpretados como
  alucinación de hash, etc.), con batería de tests (`gonzabot --selftest`).
- `gonzabot-watcher.sh` — cron liviano que enciende el servicio vLLM bajo
  demanda (por flag file) si no está corriendo. El apagado por inactividad
  lo hace el propio job de vLLM (ver `tutorial/vllm-service.sbatch`), no
  el watcher — así entre los dos no ocupan GPUs de cómputo cuando nadie
  lo está usando.

## Uso

```
./gonzabot                 # conversación normal
./gonzabot --new           # fuerza sesión nueva (ignora historial previo)
./gonzabot --selftest      # corre la batería de tests del post-procesador
```

Dentro de una sesión: `/load <archivo>` para pasarle un script existente,
`/edit` para pedir una revisión puntual, `/diagnose` para que lea el log de
un job fallido y explique la causa, `/audit` para revisar todos los jobs
activos del usuario, `/save` / `/saveall` para persistir el `sbatch` sugerido.

## Configuración

`context/core.txt` (siempre cargado) más los segmentos por familia de
software (`context/md-sim.txt`, `context/dft-qe.txt`, `context/python.txt`,
etc.) son los que se incluyen acá como ejemplo real (sitio IFIMAR).
Editables en texto plano, sin tocar código, para adaptar a otro cluster:
hardware, particiones Slurm, paquetes Spack disponibles y reglas aprendidas
de casos reales.

El endpoint del modelo (host/puerto de vLLM) se configura al principio de
`gonzabot`.

## Caso de éxito: un "investigador" IA usando gonzabot de punta a punta (30/8/2026)

Para probar gonzabot como lo usaría un usuario real — no con prompts
sintéticos de benchmark — corrimos una sesión completa donde un agente de
IA jugó el rol de un investigador de IFIMAR y usó **solo** gonzabot (nunca
una edición manual) desde la idea hasta el entregable, en una sola
terminal, contra la instancia real de producción.

**Parte 1 — una idea de investigación real, generada, sometida,
depurada y escrita.** El "investigador" propuso estudiar el comportamiento
térmico de la aleación Heusler Fe₂CrGa cerca de su temperatura de Curie
(dinámica molecular + validación DFT), le pidió a gonzabot un `sbatch` de
prueba de LAMMPS, y lo corrió de verdad. A lo largo de varias iteraciones,
esto destapó y arregló **5 bugs reales** en vivo: `spack env activate`
estrechando en silencio la visibilidad de paquetes y rompiendo hashes
válidos (lo que antes había hecho que `/diagnose` diagnosticara mal un
hash perfectamente válido como roto), un `create_box` sin `create_atoms`
después (celda de simulación vacía), un trigger de regex faltante que
hacía que un pedido de PDF con LaTeX nunca cargara la nota de sitio de
"TeXLive está roto", y — encontrado mientras se perseguía ese último bug —
un bug de documentación **a nivel de todo el cluster**: el flag
`--no-locks`, citado como "crítico" en más de 15 lugares de
`context/*.txt`, no existe en absoluto en el Spack 1.2.2 instalado
(`spack --help` no lo lista; usarlo falla de inmediato con
`unrecognized arguments`). Los cinco quedaron arreglados en `context/` y
en el post-procesador determinístico, con nuevos casos de
`--selftest`.

**Parte 2 — reproduciendo un resultado negativo real de la
literatura.** Buscamos en arXiv un paper de física de acceso abierto con
resultados negativos y elegimos el de F.-X. Coudert [*"Failure to
Reproduce the Results of 'A new transferable interatomic potential for
molecular dynamics simulations of borosilicate glasses'"*](https://arxiv.org/abs/2305.14958)
(2023) — un caso documentado donde los archivos de LAMMPS de los autores
originales tenían masas atómicas incorrectas de boro y silicio, y
"corregirlas" hace que el potencial concuerde *peor* con el experimento
(porque los parámetros B–B del potencial fueron ajustados usando esas
masas erróneas). Descargamos el archivo de input real publicado por el
propio autor (`50B/md.inp`, sin modificar) de
[fxcoudert/citable-data](https://github.com/fxcoudert/citable-data), le
pedimos a gonzabot el sbatch envolvente (limpio al primer intento, sin
bugs esta vez), y corrimos el protocolo completo de melt-quench de verdad
(3120 átomos, Buckingham + PPPM, 3.01M timesteps, ~1h15m de wall time en
32 cores de CPU):

| Fuente | Densidad (g/cm³) | Masas |
|---|---:|---|
| Experimental (Wang et al.) | 2.453 | — |
| Wang et al. 2018 (publicado) | 2.467 | **incorrectas** |
| Coudert 2023 (su reproducción) | 2.520 | correctas |
| **Esta corrida (IFIMAR, 30/8/2026)** | **2.536** | correctas |

Reprodujimos el hallazgo de Coudert de forma independiente: corregir las
masas mueve la densidad *lejos* del experimento (Δ=0,082) en vez de
acercarla, comparado con el potencial original con el bug (Δ=0,014) — y
nuestro valor queda cerca del de Coudert (Δ=0,016), una diferencia chica y
esperable entre corridas MD independientes (semilla, versión de LAMMPS,
hardware). Aclaración honesta: es una sola corrida de una sola composición
(50B de las nueve del paper) — una demo de la capacidad real de gonzabot,
no una validación independiente estadísticamente rigurosa (para eso harían
falta varias semillas).

## Tutorial: cómo lo armamos

[`tutorial/`](tutorial/) tiene la bitácora real y los scripts que usamos
para levantar todo esto en IFIMAR: servir el modelo con vLLM (con
apagado automático por inactividad), encendido bajo demanda, el wrapper
de Spack para hashes ambiguos, y notificaciones de Slurm por mail.

## Licencia

MIT — ver `LICENSE`.
