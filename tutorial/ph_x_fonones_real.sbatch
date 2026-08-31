#!/bin/bash
#SBATCH --job-name=ph_x_fonons
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=64
#SBATCH --cpus-per-task=1
#SBATCH --mem=100G
#SBATCH --time=24:00:00
#SBATCH --output=/data/home/%u/ph_x_fonons_%j.out
#SBATCH --error=/data/home/%u/ph_x_fonons_%j.err

# Directorio de trabajo
WORKDIR=/mnt/cpu-data/$USER/ph_x_fonons_$SLURM_JOB_ID
mkdir -p $WORKDIR
cd $WORKDIR

# Activar Spack
SPACK=/apps/local/spack/spack-2026b/spack/bin/spack
export SPACK_USER_CONFIG_PATH=/apps/local/spack/spack-2026b/user-config
eval $(spack load --sh quantum-espresso 2>/dev/null)
OMPI_DIR=$($SPACK location -i /2cgnkug 2>/dev/null)
export PATH=${OMPI_DIR}/bin:$PATH; export LD_LIBRARY_PATH=${OMPI_DIR}/lib

# Ejecutar ph.x con -nimage 4
mpirun -np 64 --bind-to core --map-by core ph.x -nimage 4 -in input.in
