#!/bin/bash
#SBATCH --time=24:00:00
#SBATCH --nodes=1 --ntasks-per-node=2 --cpus-per-task=2
#SBATCH --mem=20G

DATASET=$1
DATATYPE=$2
AC=$3
P_NEGATIVE=$4
VALAUC=$5

module load Julia/1.5.3-linux-x86_64
module load Python/3.9.6-GCCcore-11.2.0

source ${HOME}/sgad-env/bin/activate
export PYTHON="${HOME}/sgad-env/bin/python"
julia --project -e 'using Pkg; Pkg.build("PyCall"); @info("SETUP DONE")'

julia ./gather_alpha_scores.jl sgvae ${DATASET} ${DATATYPE} ${AC} ${P_NEGATIVE} ${VALAUC}
