using DrWatson
using Random
using DataFrames
using Statistics
using StatsBase
using EvalMetrics

# metric names and settings 
const BASE_METRICS = ["auc", "auprc", "tpr_5", "f1_5"]
const PAT_METRICS = ["pat_001", "pat_01", "pat_1", "pat_5", "pat_10", "pat_20"]
const PATN_METRICS = ["patn_5", "patn_10", "patn_50", "patn_100", "patn_500", "patn_1000"]
const PAC_METRICS = ["pac_5", "pac_10", "pac_50", "pac_100", "pac_500", "pac_1000"]
const TRAIN_EVAL_TIMES = ["fit_t", "tr_eval_t", "tst_eval_t", "val_eval_t"]
const AUC_METRICS = ["auc_100", "auc_50", "auc_20", "auc_10", "auc_5", "auc_2", 
	"auc_1", "auc_05", "auc_02", "auc_01"]

"""
	_prefix_symbol(prefix, s)

Modifies symbol `s` by adding `prefix` with underscore.
"""
_prefix_symbol(prefix, s) = Symbol("$(prefix)_$(s)")

"""
	_subsample_data(p, p_normal, labels, data; seed=nothing)

p is the amount of anomalies to include in the evaluation
1.0 means that the same number of normal and anomalous data is used
p_normal is the amount of normal data to use
"""
function _subsample_data(p, p_normal, labels, data; seed=nothing)
	# set seed
	isnothing(seed) ? nothing : Random.seed!(seed) 

	# first sample the normal data
	nn = Int(length(labels) - sum(labels))
	pnn = floor(Int, p_normal*nn)
	ninds = sample(1:nn, pnn, replace=false)
	bin_ninds = Bool.(zeros(nn))
	bin_ninds[ninds] .= true

	# then sample the anomalous data
	na = Int(sum(labels))
	pna = floor(Int, p*pnn)
	if pna > na
		throw(DomainError(p, " not enough anomalies on this threshold - $pna requested, $na available."))
	end
	ainds = sample(1:na, pna, replace=false)
	bin_ainds = Bool.(zeros(na))
	bin_ainds[ainds] .= true

	# restart the seed
	isnothing(seed) ? nothing : Random.seed!()

	# put the labels together
	inds = Bool.(zeros(length(labels)))
	inds[labels .== 0] .= bin_ninds
	inds[labels .== 1] .= bin_ainds

	# just return the samples then
	if ndims(data) == 1
		return data[inds], labels[inds], collect(1:length(labels))[inds]
	elseif ndims(data) == 2
		return data[inds,:], labels[inds], collect(1:length(labels))[inds]
	elseif ndims(data) == 3
		return data[:,:,inds], labels[inds], collect(1:length(labels))[inds]
	elseif ndims(data) == 4
		return data[:,:,:,inds], labels[inds], collect(1:length(labels))[inds]
	else
		throw("Not implemented for bigger dimension than 4.")
	end
end

"""
	_auc_at_subsamples_anomalous(p, p_normal, labels, scores; seed = nothing)
"""
function _auc_at_subsamples_anomalous(p, p_normal, labels, scores; seed = nothing)
	try
		scores, labels, _ = _subsample_data(p, p_normal, labels, scores; seed=seed)
	catch e 
		return NaN
	end
	if sum(labels) == 0.0
		return NaN
	end
	roc = EvalMetrics.roccurve(labels, scores)
	return EvalMetrics.auc_trapezoidal(roc...)
end

"""
	_precision_at(p, labels, scores)

Computes precision on portion `p` samples with highest score.
Assumes such portion of highest scoring samples is labeled positive by the model.
"""
function _precision_at(p, labels, scores)
	pN = floor(Int, p*length(labels))
	if pN > 0
		sp = sortperm(scores, rev=true)[1:pN]
		# @info sp scores[sp] labels[sp]
		return EvalMetrics.precision(labels[sp], ones(eltype(labels), pN))
	else
		return NaN
	end
end

"""
	_nprecision_at(n, labels, scores; p=0.2)

Computes precision on `n` samples but up to `p` portion of the samples with highest score.
Assumes such highest scoring samples are labeled positive by the model.
"""
function _nprecision_at(n, labels, scores; p=0.2)
	N = length(labels)
	pN = floor(Int, p*N)
	sp = sortperm(scores, rev=true)
	if n < pN
		return EvalMetrics.precision(labels[sp[1:n]], ones(eltype(labels), n))
	else
		return EvalMetrics.precision(labels[sp[1:pN]], ones(eltype(labels), pN))
	end
end

"""
	_auc_at(n, labels, scores, auc)

Computes area under roc curve on `n` samples with highest score.
If `n` is greater than sample size the provided `auc` value is returned.
"""
function _auc_at(n, labels, scores, auc)
	if n < length(labels)
		sp = sortperm(scores, rev=true)[1:n]
		l, s = labels[sp], scores[sp]
		if all(l .== 1.0)
			return 1.0 # zooming at highest scoring samples left us with positives
		elseif all(l .== 0.0)
			return 0.0 # zooming at highest scoring samples left us with negatives
        else
            try
                roc = EvalMetrics.roccurve(l, s)
                return EvalMetrics.auc_trapezoidal(roc...)
            catch
                return NaN
            end
		end
	end
	auc
end

"""
	_get_anomaly_class(r)
Due to some code legacy we have two different names for anomaly_class entries. This returns 
the correct entry or -1 if there is no anomaly_class entry.
"""
function _get_anomaly_class(r)
	if Symbol("anomaly_class") in keys(r)
		return r[:anomaly_class]
	elseif Symbol("ac") in keys(r)
		return r[:ac]
	else
		return -1
	end
end

"""
	compute_stats(r::Dict{Symbol,Any}; top_metrics_new=true)

Computes evaluation metrics from the results of experiment in serialized bson at path `f`.
Returns a DataFrame row with metrics and additional metadata for groupby's.
Hash of the model's parameters is precomputed in order to make the groupby easier.
As there are additional modes of failure in computation of top metrics (`PAT_METRICS`,...),
now there is option not to compute them by setting `top_metrics=false`.
"""
function compute_stats(r::Dict{Symbol,Any}; top_metrics_new=true)
	row = (
		modelname = r[:modelname],
		dataset = Symbol("dataset") in keys(r) ? r[:dataset] : "MVTec-AD_" * r[:category], # until the files are fixed
		phash = hash(r[:parameters]),
		parameters = savename(r[:parameters], digits=6), 
		fit_t = r[:fit_t],
		tr_eval_t = r[:tr_eval_t],
		tst_eval_t = r[:tst_eval_t],
		val_eval_t = r[:val_eval_t],
		seed = r[:seed],
		npars = (Symbol("npars") in keys(r)) ? r[:npars] : 0
	)
	
	max_seed = 10	
	anomaly_class = _get_anomaly_class(r)
	if anomaly_class != -1
		row = merge(row, (anomaly_class = anomaly_class,))
	end

	# add fs = first stage fit/eval time
	# case of ensembles and 2stage models
	if Symbol("encoder_fit_t") in keys(r)
		row = merge(row, (fs_fit_t = r[:encoder_fit_t], fs_eval_t = r[:encode_t],))
	elseif Symbol("ensemble_fit_t") in keys(r)
		row = merge(row, (fs_fit_t = r[:ensemble_fit_t], fs_eval_t = r[:ensemble_eval_t],))
	else
		row = merge(row, (fs_fit_t = 0.0, fs_eval_t = 0.0,))
	end

	for splt in ["val", "tst"]
		scores = r[_prefix_symbol(splt, :scores)]
		labels = r[_prefix_symbol(splt, :labels)]

		if length(scores) > 1
			# in cases where scores is not an 1D array
			scores = scores[:]

			invalid = isnan.(scores)
			ninvalid = sum(invalid)

			if ninvalid > 0
				invrat = ninvalid/length(scores)
				invlab = labels[invalid]
				cml = countmap(invlab)
				# we have lost the filename here due to the interface change
				@warn "Invalid stats for $(r[:modelname])/$(r[:dataset])/.../$(row[:parameters]) \t $(ninvalid) | $(invrat) | $(length(scores)) | $(get(cml, 1.0, 0)) | $(get(cml, 0.0, 0))"

				scores = scores[.~invalid]
				labels = labels[.~invalid]
				(invrat > 0.5) && error("$(splt)_scores contain too many NaN")
			end

			roc = EvalMetrics.roccurve(labels, scores)
			auc = EvalMetrics.auc_trapezoidal(roc...)
			prc = EvalMetrics.prcurve(labels, scores)
			auprc = EvalMetrics.auc_trapezoidal(prc...)

			t5 = EvalMetrics.threshold_at_fpr(labels, scores, 0.05)
			cm5 = ConfusionMatrix(labels, scores, t5)
			tpr5 = EvalMetrics.true_positive_rate(cm5)
			f5 = EvalMetrics.f1_score(cm5)

			row = merge(row, (;zip(_prefix_symbol.(splt, 
					BASE_METRICS), 
					[auc, auprc, tpr5, f5])...))

			# compute auc on a randomly selected portion of samples
			if top_metrics_new && splt == "val"
				max_seed = 10
				auc_ano_100 = [mean([_auc_at_subsamples_anomalous(p/100, 1.0, labels, scores, seed=s) for s in 1:max_seed]) 
					for p in [100.0, 50.0, 20.0, 10.0, 5.0, 2.0, 1.0, 0.5, 0.2, 0.1]]
				row = merge(row, (;zip(_prefix_symbol.(splt, map(x->x * "_100", AUC_METRICS)), auc_ano_100)...))

				auc_ano_50 = [mean([_auc_at_subsamples_anomalous(p/100, 0.5, labels, scores, seed=s) for s in 1:max_seed]) 
					for p in [100.0, 50.0, 20.0, 10.0, 5.0, 2.0, 1.0, 0.5, 0.2, 0.1]]
				row = merge(row, (;zip(_prefix_symbol.(splt, map(x->x * "_50", AUC_METRICS)), auc_ano_50)...))

				auc_ano_10 = [mean([_auc_at_subsamples_anomalous(p/100, 0.1, labels, scores, seed=s) for s in 1:max_seed]) 
					for p in [100.0, 50.0, 20.0, 10.0, 5.0, 2.0, 1.0, 0.5, 0.2, 0.1]]
				row = merge(row, (;zip(_prefix_symbol.(splt, map(x->x * "_10", AUC_METRICS)), auc_ano_10)...))

				prop_ps = [100, 50, 20, 10, 5, 2, 1]
				auc_prop_100 = [mean([_auc_at_subsamples_anomalous(1.0, p/100, labels, scores, seed=s) for s in 1:max_seed]) 
					for p in prop_ps]
				row = merge(row, (;zip(_prefix_symbol.(splt, map(x-> "auc_100_$(x)", prop_ps)), auc_prop_100)...))
			# the old way of splitting the samples
			elseif !top_metrics_new
				pat = [_precision_at(p/100.0, labels, scores) for p in [0.01, 0.1, 1.0, 5.0, 10.0, 20.0]]
				row = merge(row, (;zip(_prefix_symbol.(splt, PAT_METRICS), pat)...))

				patn = [_nprecision_at(n, labels, scores) for n in [5, 10, 50, 100, 500, 1000]]
				row = merge(row, (;zip(_prefix_symbol.(splt, PATN_METRICS), patn)...))	

				pac = [_auc_at(n, labels, scores, auc) for n in [5, 10, 50, 100, 500, 1000]]
				row = merge(row, (;zip(_prefix_symbol.(splt, PAC_METRICS), pac)...))
			end
		else
			error("$(splt)_scores contain only one value")
		end
	end

	DataFrame([row])
end

"""
	aggregate_stats_mean_max(df::DataFrame, criterion_col=:val_auc; 
					min_samples=("anomaly_class" in names(df) && maximum(df[:anomaly_class]) > 0) ? 10 : 3,
								downsample=Dict(), add_col=nothing)

Agregates eval metrics by seed/anomaly class over a given hyperparameter and then chooses best
model based on `criterion_col`. The output is a DataFrame of maximum #datasets*#models rows with
columns of different types
- identifiers - `dataset`, `modelname`, `phash`, `parameters`
- averaged metrics - both from test and validation data such as `tst_auc`, `val_pat_10`, etc.
- std of best hyperparameter computed for each metric over different seeds, suffixed `_std`
- std of best 10 hyperparameters computed over averaged metrics, suffixed `_top_10_std`
- samples involved in the aggregation, 
	+ `psamples` - number of runs of the best hyperparameter
	+ `dsamples` - number of sampled hyperparameters
	+ `dsamples_valid` - number of sampled hyperparameters with enough runs
When nonempty `downsample` dictionary is specified, the entries of`("model" => #samples)`, specify
how many samples should be taken into acount. These are selected randomly with fixed seed.
Optional arg `min_samples` specifies how many seed/anomaly_class combinations should be present
in order for the hyperparameter's results be considered statistically significant.
Optionally with argument `add_col` one can specify additional column to average values over.
"""
function aggregate_stats_mean_max(df::DataFrame, criterion_col=:val_auc;  agg_cols=[],
							min_samples=("anomaly_class" in names(df) && maximum(df[:anomaly_class]) > 0) ? 10 : 3,
							downsample=Dict(), add_col=nothing, verbose=true, dseed=40, topn=1)
	if length(agg_cols) == 0 # use automatic agg cols
		agg_cols = vcat(_prefix_symbol.("val", BASE_METRICS), _prefix_symbol.("tst", BASE_METRICS))
		agg_cols = vcat(agg_cols, _prefix_symbol.("val", PAT_METRICS), _prefix_symbol.("tst", PAT_METRICS))
		agg_cols = vcat(agg_cols, _prefix_symbol.("val", PATN_METRICS), _prefix_symbol.("tst", PATN_METRICS))
		agg_cols = vcat(agg_cols, _prefix_symbol.("val", PAC_METRICS), _prefix_symbol.("tst", PAC_METRICS))
		agg_cols = vcat(agg_cols, Symbol.(TRAIN_EVAL_TIMES))
		agg_cols = (add_col !== nothing) ? vcat(agg_cols, add_col) : agg_cols
	end
	top10_std_cols = _prefix_symbol.(agg_cols, "top_10_std")

	# agregate by seed over given hyperparameter and then choose best
	results = []
	for (dkey, dg) in pairs(groupby(df, :dataset))
		for (mkey, mg) in pairs(groupby(dg, :modelname))
			n = length(unique(mg.phash))
			# downsample models given by the `downsample` dictionary
			Random.seed!(dseed)
			pg = (mkey.modelname in keys(downsample)) && (downsample[mkey.modelname] < n) ? 
					groupby(mg, :phash)[randperm(n)[1:downsample[mkey.modelname]]] : 
					groupby(mg, :phash)
			Random.seed!()
			
			# filter only those hyperparameter that have sufficient number of samples
			mg_suff = reduce(vcat, [g for g in pg if nrow(g) >= min_samples])
			
			# for some methods and threshold the data frame is empty
			if nrow(mg_suff) > 0
				# aggregate over the seeds
				pg_agg = combine(groupby(mg_suff, :phash), 
							nrow => :psamples, 
							agg_cols .=> mean .=> agg_cols, 
							agg_cols .=> std, 
							:parameters => unique => :parameters) 
				
				# sort by criterion_col
				sort!(pg_agg, order(criterion_col, rev=true))
				topn = min(size(pg_agg,1), topn)
				best = pg_agg[topn:topn, :]

				# add std of top 10 models metrics
				best_10_std = combine(first(pg_agg, 10), agg_cols .=> std .=> top10_std_cols)
				best = hcat(best, best_10_std)
				
				# add grouping keys
				best[:dataset] = dkey.dataset
				best[:modelname] = mkey.modelname
				best[:dsamples] = n
				best[:dsamples_valid] = nrow(pg_agg)

				push!(results, best)
			end
		end
	end
	vcat(results...)
end


"""
aggregate_stats_max_mean(df::DataFrame, criterion_col=:val_auc; 
							downsample=Dict(), add_col=nothing)

Chooses the best hyperparameters for each seed/anomaly_class combination by `criterion_col`
and then aggregates the metrics over seed/anomaly_class to get the final results. The output 
is a DataFrame of maximum #datasets*#models rows with
columns of different types
- identifiers - `dataset`, `modelname`
- averaged metrics - both from test and validation data such as `tst_auc`, `val_pat_10`, etc.
- std of best hyperparameters computed for each metric over different seeds, suffixed `_std`
- std of best 10 hyperparameters in each seed then averaged over seeds, suffixed `_top_10_std`
When nonempty `downsample` dictionary is specified, the entries of`("model" => #samples)`, specify
how many samples should be taken into acount. These are selected randomly with fixed seed.
As oposed to mean-max aggregation the output does not contain parameters and phash.
Optionally with argument `add_col` one can specify additional column to average values over.
"""
function aggregate_stats_max_mean(df::DataFrame, criterion_col=:val_auc; agg_cols=[],
									downsample=Dict(), add_col=nothing, verbose=true, 
									dseed=40, topn=1, results_per_ac=false)
	if length(agg_cols) == 0 # use automatic agg cols
		agg_cols = vcat(_prefix_symbol.("val", BASE_METRICS), _prefix_symbol.("tst", BASE_METRICS))
		agg_cols = vcat(agg_cols, _prefix_symbol.("val", PAT_METRICS), _prefix_symbol.("tst", PAT_METRICS))
		agg_cols = vcat(agg_cols, _prefix_symbol.("val", PATN_METRICS), _prefix_symbol.("tst", PATN_METRICS))
		agg_cols = vcat(agg_cols, _prefix_symbol.("val", PAC_METRICS), _prefix_symbol.("tst", PAC_METRICS))
		agg_cols = vcat(agg_cols, Symbol.(TRAIN_EVAL_TIMES))
		agg_cols = (add_col !== nothing) ? vcat(agg_cols, add_col) : agg_cols
	end
	top10_std_cols = _prefix_symbol.(agg_cols, "top_10_std")

	agg_keys = ("anomaly_class" in names(df)) ? [:seed, :anomaly_class] : [:seed]
	# choose best for each seed/anomaly_class cobination and average over them
	results = []
	results_pac = []
	for (dkey, dg) in pairs(groupby(df, :dataset))
		for (mkey, mg) in pairs(groupby(dg, :modelname))
			partial_results = []

			# if there is only the dummy class don't print the warnings for missing anomaly class
			if ("anomaly_class" in names(df)) && maximum(mg[:anomaly_class]) > 0
				classes = unique(mg.anomaly_class)
				dif = setdiff(collect(1:10), classes)
				if (length(classes) < 10) && verbose
					@warn "$(mkey.modelname) - $(dkey.dataset): missing runs on anomaly_class $(dif)."
				end
			else
				seeds = unique(mg.seed)
				dif = setdiff(collect(1:5), seeds)
				if (length(seeds) < 3) && verbose
					@warn "$(mkey.modelname) - $(dkey.dataset): missing runs on seed $(dif)."
				end
			end

			# iterate over seed-anomaly_class groups
			for (skey, sg) in pairs(groupby(mg, agg_keys))
				n = nrow(sg)
				# downsample the number of hyperparameter if needed
				Random.seed!(dseed)
				ssg = (mkey.modelname in keys(downsample)) && (downsample[mkey.modelname] < n) ? 
						sg[randperm(n)[1:downsample[mkey.modelname]], :] : sg
				Random.seed!()
				
				sssg = sort(ssg, order(criterion_col, rev=true))
				# best hyperparameter after sorting by criterion_col
				topn = min(size(sssg,1), topn)
				best = sssg[topn:topn,:]
				
				# add std of top 10 models metrics
				best_10_std = combine(first(sssg, 10), agg_cols .=> std .=> top10_std_cols)
				best = hcat(best, best_10_std)
				
				push!(partial_results, best)
			end

			best_per_seed = reduce(vcat, partial_results)
			push!(results_pac, best_per_seed)
			# average over seed-anomaly_class groups
			best = combine(best_per_seed,  
						agg_cols .=> mean .=> agg_cols, 
						top10_std_cols .=> mean .=> top10_std_cols,
						agg_cols .=> std) 
			
			# add grouping keys
			best[:dataset] = dkey.dataset
			best[:modelname] = mkey.modelname
		
			push!(results, best)
		end
	end
	if results_per_ac
		return vcat(results...), vcat(results_pac...)
	else
		return vcat(results...)
	end
end
