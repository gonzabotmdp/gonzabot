# Tutorial: cómo armamos gonzabot en IFIMAR

Esto no es un instalador — es la bitácora real de los pasos y scripts que
usamos para levantar gonzabot en nuestro cluster, para que otro admin de
HPC pueda replicar el criterio (no necesariamente cada comando literal,
que va a depender de su propia infraestructura).

Nota sobre rutas: vas a ver `/data/gpu/...` en algunos scripts y
`/mnt/gpu-data/...` en otros para el mismo directorio — no es un error de
tipeo. Es el mismo NFS montado con nombres distintos según el nodo: los
nodos de login usan `/data/cpu/` y `/data/gpu/`, los nodos de cómputo usan
`/mnt/cpu-data/` y `/mnt/gpu-data/`. `gonzabot-watcher.sh` corre en un nodo
de login (por eso `/data/gpu/...`); `vllm-service.sbatch` corre dentro de
un job en un nodo de cómputo (por eso `/mnt/gpu-data/...`). Adaptalo al
esquema de mounts real de tu propio cluster.

## 1. Servir el modelo con vLLM

`download-model.sh` — bajamos el modelo desde HuggingFace con
`huggingface_hub.snapshot_download` (acá con Llama 3.3 70B de ejemplo;
nosotros terminamos usando Qwen2.5-72B-Instruct-AWQ en producción, ver
`vllm-service.sbatch`).

`vllm-service.sbatch` — el job de Slurm real que levanta el servicio.
Dos ideas del script que vale la pena copiar tal cual:

- **Vive en la partición `inference`** (no `gpu`), como un servicio de
  larga duración (`--time=16:00:00`) en vez de un job de cómputo puntual.
- **Watchdog de inactividad integrado**: un subproceso en background
  (`while sleep 60; do ...`) chequea un archivo "heartbeat" — cada
  request de gonzabot lo toca — y si pasan `IDLE_MINUTES` sin actividad,
  se cancela el propio job (`scancel $SLURM_JOB_ID`). Así el servicio no
  ocupa GPUs de cómputo cuando nadie lo está usando, sin necesitar un
  daemon externo.

## 2. Encendido bajo demanda

El servicio arriba se cae solo por inactividad — pero alguien tiene que
volver a prenderlo cuando un usuario lo necesita. Eso lo hace
[`gonzabot-watcher.sh`](../gonzabot-watcher.sh) (raíz del repo): un cron
liviano (corrido por un usuario normal, sin root) que revisa un flag file
cada minuto y somete `vllm-service.sbatch` si hace falta.

## 3. Resolución de hashes ambiguos en Spack

`spack-load-wrapper.txt` — el problema y la solución real que encontramos
cuando `spack load paquete` fallaba por tener múltiples builds instalados
del mismo paquete (`Error: fftw matches multiple packages`). Wrapper que
redefine `spack load` para resolver el hash preferido automáticamente.

## 4. Notificaciones de Slurm por mail

`slurm-mail-notifications.txt` — cómo arreglamos `--mail-user`/`--mail-type`
cuando `sendmail` venía deshabilitado por defecto (`/bin/false`), con
`ssmtp` como relay SMTP liviano (Gmail App Password o SMTP institucional).

## Lo que NO está acá

Dejamos afuera la configuración de VPN/firewall (WireGuard + OPNsense) que
usamos para dar acceso a colaboradores externos — no por ser complicada,
sino porque el documento real tiene la topología de red completa de
nuestra institución (IPs públicas, reglas de firewall). El patrón general
es simple igual: WireGuard corriendo directo en el firewall perimetral, un
peer por colaborador externo, `AllowedIPs` acotado solo al nodo de login
(nunca `0.0.0.0/0`) para no romper la red del usuario.

## Cómo se relaciona con el "conocimiento" del cluster

Todo lo de arriba es infraestructura — se configura una vez. El
`context/*.txt` en la raíz del repo es distinto: es el conocimiento
específico del cluster (hardware, particiones, paquetes Spack, reglas
aprendidas de bugs reales de usuarios) que gonzabot usa en cada
conversación. Para adaptar gonzabot a otro cluster, la infraestructura de
acá arriba se replica una vez; el `context/` se reescribe por completo con
los datos reales del cluster propio.
