#!/bin/bash
# this runs the computation for all datasets and score types at once
FORCE=$1

for AC in {1..10}
do
	./compute_knn_scores_per_class_parallel.sh ../experiments_images/datasets_images_color.txt leave-one-in $AC $FORCE
done