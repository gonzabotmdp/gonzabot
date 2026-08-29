# gonzabot

![license](https://img.shields.io/badge/license-MIT-blue) ![python](https://img.shields.io/badge/python-3%20stdlib%20only-green)

Asistente de IA para usuarios de un cluster HPC (Slurm + Spack), pensado para
encontrar errores de configuración, malos usos de recursos y pedidos
exagerados de recursos en scripts `sbatch` **antes** de que el job corra y
falle o desperdicie horas de cómputo.

Corre sobre un modelo local vía [vLLM](https://github.com/vllm-project/vllm)
(probado con Qwen2.5-72B-Instruct-AWQ), sin dependencias externas de Python
más allá de la librería estándar.

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
- Quantum ESPRESSO (`--ntasks` no proporcional a `-nimage`/`-npool`): **~1.3x**
  más rápido.

Ejemplo real del caso Quantum ESPRESSO — el usuario pedía paralelismo por
imágenes/pools sin escalar `--ntasks`, así que casi todo el paralelismo
pedido quedaba sin usarse:

```diff
 #SBATCH --nodes=1
-#SBATCH --ntasks=1
+#SBATCH --ntasks=4
 #SBATCH --cpus-per-task=1

 pw.x -nimage 4 -npool 1 -in input.pwi
```

`-nimage 4` le pide a QE que reparta el trabajo en 4 imágenes independientes,
pero con `--ntasks=1` Slurm solo le da un proceso MPI para repartir entre las
4 — se serializan. Con `--ntasks=4` cada imagen corre en su propio proceso.

## Arquitectura

- `gonzabot` — CLI interactivo en Python 3 puro (stdlib únicamente:
  `sqlite3` para persistir sesiones, `urllib` para hablar con el endpoint
  OpenAI-compatible de vLLM). Sin `pip install` necesario.
- `context/` — archivos de texto plano que se inyectan como contexto del
  cluster (hardware, particiones, software instalado vía Spack, reglas
  aprendidas de bugs reales). Son el "conocimiento" específico del sitio;
  para adaptar gonzabot a otro cluster, se reescriben estos archivos.
- Post-procesamiento determinístico (no depende del LLM) sobre el `sbatch`
  generado: detecta y corrige patrones frecuentes (heredocs mal citados,
  `cd $WORKDIR` inyectado sobre rutas relativas que ya funcionaban, `\$`
  espurios fuera de heredoc, `module load` con nombre de paquete ambiguo en
  Spack, etc.), con batería de tests (`gonzabot --selftest`).
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
un job fallido y explique la causa, `/save` / `/saveall` para persistir el
`sbatch` sugerido.

## Configuración

`context/core.txt`, `context/hpc.txt` y `context/python.txt` son los que
se incluyen acá como ejemplo real (sitio IFIMAR). Editables en texto plano,
sin tocar código, para adaptar a otro cluster: hardware, particiones Slurm,
paquetes Spack disponibles y reglas aprendidas de casos reales.

El endpoint del modelo (host/puerto de vLLM) se configura al principio de
`gonzabot`.

## Tutorial: cómo lo armamos

[`tutorial/`](tutorial/) tiene la bitácora real y los scripts que usamos
para levantar todo esto en IFIMAR: servir el modelo con vLLM (con
apagado automático por inactividad), encendido bajo demanda, el wrapper
de Spack para hashes ambiguos, y notificaciones de Slurm por mail.

## Licencia

MIT — ver `LICENSE`.
