#!/bin/bash

MODEL=$1
DATASET_FILE=$2
LATENT_SCORE=$3
ANOMALY_CLASS=$4
BASE_BETA=$5
VAL_CLASSES=$6
FORCE=$7

LOG_DIR="${HOME}/logs/supervised_alpha_scores"

if [ ! -d "$LOG_DIR" ]; then
    mkdir $LOG_DIR
fi

while read d; do
    # submit to slurm
    sbatch \
    --output="${LOG_DIR}/${d}_${MODEL}_${LATENT_SCORE}_${ANOMALY_CLASS}_${VAL_CLASSES}_%A.out" \
     ./alpha_scores.sh $MODEL $d ${LATENT_SCORE} ${ANOMALY_CLASS} ${BASE_BETA} ${VAL_CLASSES} $FORCE
done < ${DATASET_FILE}
