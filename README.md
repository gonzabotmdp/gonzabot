# gonzabot

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

## Case study: an AI "researcher" using gonzabot end-to-end (30/8/2026)

*(This section is in English for international context — the rest of the
README, and the actual gonzabot session logs, are in Spanish, since that's
the real language spoken at IFIMAR.)*

To stress-test gonzabot the way a real user would — not synthetic
benchmark prompts — we ran a full session where an AI agent played the
role of an IFIMAR researcher and used **only** gonzabot (never a manual
edit) from idea to deliverable, in a single terminal, against the live
production instance.

**Part 1 — a real research idea, generated, submitted, debugged, and
written up.** The "researcher" proposed studying the thermal behavior of
the Heusler alloy Fe₂CrGa near its Curie temperature (molecular dynamics
+ DFT validation), asked gonzabot for a test LAMMPS `sbatch`, and ran it
for real. Over several iterations, this surfaced and fixed **5 genuine
bugs** live: `spack env activate` silently narrowing package visibility
and breaking valid hashes (which had earlier caused `/diagnose` to
misdiagnose a perfectly valid hash as broken), a `create_box` with no
`create_atoms` afterward (empty simulation cell), a missing regex trigger
that meant a LaTeX/PDF request never loaded the site's "TeXLive is
currently broken" note, and — found while chasing that last one down — a
**cluster-wide** documentation bug: the `--no-locks` flag referenced as
"critical" in 15+ places across `context/*.txt` doesn't exist at all in
the installed Spack 1.2.2 (`spack --help` doesn't list it; using it fails
immediately with `unrecognized arguments`). All five are fixed in
`context/` and the deterministic post-processor, with new `--selftest`
cases.

**Part 2 — reproducing a real negative result from the literature.** We
searched arXiv for an open-access negative-results physics paper and
picked F.-X. Coudert's [*"Failure to Reproduce the Results of 'A new
transferable interatomic potential for molecular dynamics simulations of
borosilicate glasses'"*](https://arxiv.org/abs/2305.14958) (2023) — a
documented case where the original authors' LAMMPS files had incorrect
boron/silicon atomic masses, and "fixing" them makes the potential agree
*worse* with experiment (because the potential's B–B parameters were
themselves fit against the buggy masses). We downloaded the author's own
published input file (`50B/md.inp`, unmodified) from
[fxcoudert/citable-data](https://github.com/fxcoudert/citable-data), had
gonzabot generate the wrapping `sbatch` on the first try (no bugs this
time), and ran the full melt-quench protocol for real (3120 atoms,
Buckingham + PPPM, 3.01M timesteps, ~1h15m wall time on 32 CPU cores):

| Source | Density (g/cm³) | Masses |
|---|---:|---|
| Experimental (Wang et al.) | 2.453 | — |
| Wang et al. 2018 (as published) | 2.467 | **incorrect** |
| Coudert 2023 (his reproduction) | 2.520 | correct |
| **This run (IFIMAR, 30/8/2026)** | **2.536** | correct |

We reproduced Coudert's finding independently: correcting the masses
moves the density *away* from experiment (Δ=0.082) rather than toward it,
compared to the original buggy potential (Δ=0.014) — and our value lands
close to Coudert's own (Δ=0.016), a small and expected gap between
independent MD runs (seed, LAMMPS version, hardware). Honest caveat: this
is a single run of a single composition (50B out of the paper's nine) —
a demo of gonzabot's real-world capability, not a statistically rigorous
independent validation (that would need multiple seeds).

## Tutorial: cómo lo armamos

[`tutorial/`](tutorial/) tiene la bitácora real y los scripts que usamos
para levantar todo esto en IFIMAR: servir el modelo con vLLM (con
apagado automático por inactividad), encendido bajo demanda, el wrapper
de Spack para hashes ambiguos, y notificaciones de Slurm por mail.

## Licencia

MIT — ver `LICENSE`.
