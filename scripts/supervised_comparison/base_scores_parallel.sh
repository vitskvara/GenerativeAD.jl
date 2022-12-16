#!/bin/bash

MODEL=$1
DATASET_FILE=$2
ANOMALY_CLASS=$3
VAL_CLASSES=$4
FORCE=$5

LOG_DIR="${HOME}/logs/supervised_base_scores"

if [ ! -d "$LOG_DIR" ]; then
    mkdir $LOG_DIR
fi

while read d; do
    # submit to slurm
    sbatch \
    --output="${LOG_DIR}/${d}_${MODEL}_${ANOMALY_CLASS}_${VAL_CLASSES}_%A.out" \
     ./base_scores.sh $MODEL $d ${ANOMALY_CLASS} ${VAL_CLASSES} $FORCE
done < ${DATASET_FILE}
