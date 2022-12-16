using DrWatson
@quickactivate
using GenerativeAD
using PyCall
using BSON, FileIO, DataFrames
using EvalMetrics
using OrderedCollections
using ArgParse
using Suppressor
using StatsBase
using Random
using GenerativeAD.Evaluation: _prefix_symbol, _get_anomaly_class, _subsample_data
using GenerativeAD.Evaluation: BASE_METRICS, AUC_METRICS

function basic_stats(labels, scores)
	try
		roc = EvalMetrics.roccurve(labels, scores)
		auc = EvalMetrics.auc_trapezoidal(roc...)
		prc = EvalMetrics.prcurve(labels, scores)
		auprc = EvalMetrics.auc_trapezoidal(prc...)

		t5 = EvalMetrics.threshold_at_fpr(labels, scores, 0.05)
		cm5 = ConfusionMatrix(labels, scores, t5)
		tpr5 = EvalMetrics.true_positive_rate(cm5)
		f5 = EvalMetrics.f1_score(cm5)

		return auc, auprc, tpr5, f5
	catch e
		if isa(e, ArgumentError)
			return NaN, NaN, NaN, NaN
		else
			rethrow(e)
		end
	end
end

auc_val(labels, scores) = EvalMetrics.auc_trapezoidal(EvalMetrics.roccurve(labels, scores)...)

function perf_at_p_basic(p, p_normal, val_scores, val_y, tst_scores, tst_y; seed=nothing)
	scores, labels, _ = try
		_subsample_data(p, p_normal, val_y, val_scores; seed=seed)
	catch e
		return NaN, NaN
	end
	# if there are no positive samples return NaNs
	if sum(labels) == 0
		val_auc = NaN
		tst_auc = auc_val(tst_y, tst_scores[:,1])
	# if top samples are only positive
	# we cannot train alphas
	# therefore we return the default val performance
	elseif sum(labels) == length(labels) 
		val_auc = NaN
		tst_auc = auc_val(tst_y, tst_scores[:,1])
	# if they are not only positive, then we train alphas and use them to compute 
	# new scores - auc vals on the partial validation and full test dataset
	else
        # predict
		val_auc = auc_val(labels, scores)
		tst_auc = auc_val(tst_y, tst_scores)
	end
	return val_auc, tst_auc
end

function perf_at_p_basic_agg(args...; kwargs...)
	results = [perf_at_p_basic(args...;seed=seed, kwargs...) for seed in 1:max_seed_perf]
	return nanmean([x[1] for x in results]), nanmean([x[2] for x in results])
end

function perf_at_p_new(p, p_normal, val_scores, val_y, tst_scores, tst_y, init_alpha, alpha0, base_beta; 
	seed=nothing, scale=true, kwargs...)
	scores, labels, _ = try
		_subsample_data(p, p_normal, val_y, val_scores; seed=seed)
	catch e
		return NaN, NaN
	end
	# if there are no positive samples return NaNs
	if sum(labels) == 0
		val_auc = NaN
		tst_auc = auc_val(tst_y, tst_scores[:,1])
	# if top samples are only positive
	# we cannot train alphas
	# therefore we return the default val performance
	elseif sum(labels) == length(labels) 
		val_auc = NaN
		tst_auc = auc_val(tst_y, tst_scores[:,1])
	# if they are not only positive, then we train alphas and use them to compute 
	# new scores - auc vals on the partial validation and full test dataset
	else
		try
			# get the logistic regression model
            model = if method == "logreg"
                LogReg()
            elseif method == "probreg"
                ProbReg()
            elseif method == "robreg"
               	_init_alpha, _alpha0 = if occursin("sgvaegan", modelname)
			    	compute_alphas(scores, labels) # determine them based on the best score
			    else 
			    	init_alpha, alpha0 # global values
			    end
                RobReg(input_dim = size(scores,2), alpha=_init_alpha, alpha0=_alpha0, 
                	beta=base_beta/sum(labels))
            else
                error("unknown method $method")
            end

            # fit
            if method == "logreg"
                fit!(model, scores, labels)
            elseif method == "probreg"
                fit!(model, scores, labels; verb=false, early_stopping=true, patience=10, balanced=true)
            elseif method == "robreg"
            	try
            		fit!(model, scores, labels; verb=false, early_stopping=true, scale=scale, patience=10,
                    balanced=true)
                catch e
	            	if isa(e, PyCall.PyError)
			            return NaN, NaN
			        else
			        	rethrow(e)
			        end
			    end 
            end

            # predict
			val_probs = predict(model, scores, scale=scale)
			tst_probs = predict(model, tst_scores, scale=scale)
			val_auc = auc_val(labels, val_probs)
			tst_auc = auc_val(tst_y, tst_probs)
		catch e
			if isa(e, LoadError) || isa(e, ArgumentError)
				val_prec = NaN
				val_auc = NaN
				tst_auc = auc_val(tst_y, tst_scores[:,1])
			else
				rethrow(e)
			end
		end
	end
	return val_auc, tst_auc
end	

# this is the version for the supervised classifier
function perf_at_p_new(p, p_normal, tr_x::AbstractArray{T,4}, tr_y, tst_x::AbstractArray{T,4}, tst_y, 
	parameters, niters; seed=nothing, kwargs...) where T
	x, y, _ = try
		_subsample_data(p, p_normal, tr_y, tr_x; seed=seed)
	catch e
		return NaN, NaN
	end
	# if there are samples only from one class return NaNs
	if sum(y) <= 1 || sum(y) == length(y) 
		return NaN, NaN
	else
		try
			parameters = merge(parameters, (batchsize=min(parameters.batchsize, floor(Int,sum(y)/2)*2),))
			@info "Trying to fit with $(parameters), seed=$seed..."
			model, history, tr_probs, tst_probs = fit_classifier(x, y, tst_x, tst_y, parameters, niters)
			@info "Done."
			return auc_val(y, tr_probs), auc_val(tst_y, tst_probs)
		catch e
			rethrow(e)
		end
	end
end	

nanmean(x) = mean(x[.!isnan.(x)])
function topn_mean(vs, ts, n)
    inds = .!isnan.(vs) .& .!isnan.(ts)
    vs, ts = vs[inds], ts[inds]
    _n = min(n, length(vs))
    if _n > 0
        inds = sortperm(vs, rev=true)
        return mean(vs[inds][1:_n]), mean(ts[inds][1:_n])
    else
        return NaN, NaN
    end
end

function perf_at_p_agg(args...; kwargs...)
	results = [perf_at_p_new(args...;seed=seed, kwargs...) for seed in 1:max_seed_perf]
	results = results[.!map(x->any(isnan.(x)), results)]
	return topn_mean([x[1] for x in results], [x[2] for x in results], 4)
end

function get_random_latent_files(model_id, lfs, n=10)
	_lfs = filter(x->occursin("$(model_id)",x), lfs)
	sample(_lfs, min(n, length(_lfs)), replace=false)
end

# get the right lf when using a selection of best models
function get_latent_file(_params, lfs)
	lst = get(_params, "latent_score_type", "knn")
	if lst != latent_score_type
		return nothing
	end

	model_id = _params["init_seed"]
	_lfs = filter(x->occursin("$(model_id)",x), lfs)
	_lfs = if lst == "knn"
		k = _params["k"]
		v = _params["v"]
		filter(x->occursin("k=$(k)_",x) && occursin("v=$v",x), _lfs)
	else
		_lfs
	end
	if length(_lfs) > 1
		error("something wrong when processing $(_params)")
	elseif length(_lfs) == 0
		return
	end
	return _lfs[1]
end

function prepare_savefile(save_dir, lf, base_beta, method)
	outf = joinpath(save_dir, split(lf, ".")[1])
	outf *= "_beta=$(base_beta)_method=$(method).bson"
	@info "Working on $outf"
	if !force && isfile(outf)
		@info "Already present, skipping."
        return ""
	end	
	return outf
end

function extended_savename(ps)
	f(x,y) = "$x-$y"
	ps = merge(ps, (kernelsizes = reduce(f, ps.kernelsizes),))
	ps = merge(ps, (scalings = reduce(f, ps.scalings),))
	ps = merge(ps, (channels = reduce(f, ps.channels),))
	savename(ps, "bson")
end

# this is the version for classifier
function prepare_savefile(save_dir, params)
	outf = joinpath(save_dir, extended_savename(params))
	@info "Working on $outf"
	return outf
end

function load_scores(model_id, lf, latent_dir, rfs, res_dir, modelname="sgvae")
	# load the saved scores
	ldata = load(joinpath(latent_dir, lf))
	if isnan(ldata[:val_scores][1])
		@info "Latent score data not found or corrupted"
		return nothing, nothing, nothing, nothing, nothing, nothing
	end
	y_val = ldata[:val_labels];
	y_tst = ldata[:tst_labels];
	
	if modelname == "sgvae"
		rf = filter(x->occursin("$(model_id)", x), rfs)
		if length(rf) < 1
			@info "Something is wrong, original score file for $lf not found"
			return nothing, nothing, nothing, nothing, nothing, nothing
		end
		rf = rf[1]
		rdata = load(joinpath(res_dir, rf))

		# prepare the data
		if isnothing(rdata[:val_scores]) || isnothing(rdata[:tst_scores])
			@info "Normal score data not available."
			return nothing, nothing, nothing, nothing, nothing, nothing
		end

		scores_val = cat(rdata[:val_scores], transpose(ldata[:val_scores]), dims=2);
		scores_tst = cat(rdata[:tst_scores], transpose(ldata[:tst_scores]), dims=2);
	elseif occursin("sgvaegan", modelname)
		rf = filter(x->occursin("$(model_id)", x), rfs)
		rf = filter(x->!occursin("model", x), rf)
		if length(rf) != 3
			@info "Something is wrong, found $(length(rf)) score files instead of 3 for score file $lf."
			return nothing, nothing, nothing, nothing, nothing, nothing
		end
		rdata = map(r->load(joinpath(res_dir, r)), rf)

		if any(map(r->isnothing(r[:val_scores]), rdata)) || any(map(r->isnothing(r[:tst_scores]), rdata))
			@info "Normal score data not available."
			return nothing, nothing, nothing, nothing, nothing, nothing
		end

		# make sure that the score are always in the same order
		score_types = ["discriminator", "feature_matching", "reconstruction"]
		rscores = Dict()
		for rd in rdata
			rscores[rd[:parameters].score * "_val"] = rd[:val_scores]
			rscores[rd[:parameters].score * "_tst"] = rd[:tst_scores] 
		end
		rscores_val = cat(map(st->rscores[st * "_val"], score_types)..., dims=2)
		rscores_tst = cat(map(st->rscores[st * "_tst"], score_types)..., dims=2)
		
		scores_val = cat(rscores_val, transpose(ldata[:val_scores]), dims=2);
		scores_tst = cat(rscores_tst, transpose(ldata[:tst_scores]), dims=2);
	end

	return scores_val, scores_tst, y_val, y_tst, ldata, rdata
end

function original_class_split(dataset, ac; seed=1, ratios=(0.6,0.2,0.2))
	# get the original data with class labels
	if dataset == "wildlife_MNIST"
		(xn, cn), (xa, ca) = GenerativeAD.Datasets.load_wildlife_mnist_data(normal_class_ind=ac);
	elseif (dataset in GenerativeAD.Datasets.mldatasets)
		# since the functions for MLDatasets.MNIST, MLDatasets.CIFAR10 are the same
		sublib = getfield(GenerativeAD.Datasets.MLDatasets, Symbol(dataset))
		labels = cat(sublib.trainlabels(), sublib.testlabels(), dims=1)
		label_list = unique(labels)
		class_ind = label_list[ac] # this sucks but it has to be here because of old code 
		_labels = deepcopy(labels) # because of that, we also need to relabel the labels
		map(l->_labels[labels .== l[2]] .= l[1], enumerate(label_list))
		# (see GenerativeAD.Datasets.load_mldatasets_data)
		cn, ca = _labels[labels.==class_ind], _labels[labels.!=class_ind]
	elseif dataset == "cocoplaces"
		(xn, cn), (xa, ca) = GenerativeAD.Datasets.load_cocoplaces_data(normal_class_ind=ac);
	else
		throw("Dataset $dataset not implemented")
	end
	# then get the original labels in the same splits as we have the scores
	(c_tr, y_tr), (c_val, y_val), (c_tst, y_tst) = GenerativeAD.Datasets.train_val_test_split(cn,ca,ratios; 
		seed=seed)
	return (c_tr, y_tr), (c_val, y_val), (c_tst, y_tst)
end

# this splits the 10 classes into two halves - one anomalous, one normal
function divide_classes(ac, nval=5)
	all_acs = repeat(collect(1:10), 3)
	iac = 10 + ac
	acsn = all_acs[iac:iac+nval-1]
	acsa = all_acs[iac-(10-nval):iac-1]
	return acsn, acsa
end

function basic_experiment(val_scores, val_y, tst_scores, tst_y, outf, base_beta, init_alpha, alpha0, 
	scale, dataset, rdata, ldata, seed, ac, method, score_type, latent_score_type)
	# setup params
	parameters = merge(ldata[:parameters], (beta=base_beta, init_alpha=init_alpha, alpha0=alpha0, scale=scale))
	save_modelname = modelname*"_$method"

	res_df = @suppress begin
		# prepare the result dataframe
		res_df = OrderedDict()
		res_df["modelname"] = save_modelname
		res_df["dataset"] = dataset
		res_df["phash"] = GenerativeAD.Evaluation.hash(parameters)
		res_df["parameters"] = "_"*savename(parameters)
		res_df["fit_t"] = rdata[:fit_t]
		res_df["tr_eval_t"] = ldata[:tr_eval_t] + rdata[:tr_eval_t]
		res_df["val_eval_t"] = ldata[:val_eval_t] + rdata[:val_eval_t]
		res_df["tst_eval_t"] = ldata[:tst_eval_t] + rdata[:tst_eval_t]
		res_df["seed"] = seed
		res_df["npars"] = rdata[:npars]
		res_df["anomaly_class"] = ac
		res_df["method"] = method
		res_df["score_type"] = score_type
		res_df["latent_score_type"] = latent_score_type

		# fit the logistic regression - first on all the validation data
		# first, filter out NaNs and Infs
		inds = vec(mapslices(r->!any(r.==Inf), val_scores, dims=2))
		val_scores = val_scores[inds, :]
		val_y = val_y[inds]
		inds = vec(mapslices(r->!any(isnan.(r)), val_scores, dims=2))
		val_scores = val_scores[inds, :]
		val_y = val_y[inds]

        # get the logistic regression model - scale beta by the number of anomalies
      	_init_alpha, _alpha0 = if occursin("sgvaegan", modelname)
	    	compute_alphas(val_scores, val_y) # determine them based on the best score
	    else 
	    	init_alpha, alpha0 # global values
	    end
		model = RobReg(input_dim = size(val_scores,2), alpha=_init_alpha, beta=base_beta/sum(val_y), 
        	alpha0=_alpha0)
        
        # fit
        converged = true
    	try
            fit!(model, val_scores, val_y; verb=false, early_stopping=true, scale=scale, patience=10,
                balanced=true)
        catch e
        	if isa(e, PyCall.PyError)
        		converged = false
	        else
	        	rethrow(e)
	        end
	    end
        if converged
	        val_probs = predict(model, val_scores, scale=scale)
	        tst_probs = predict(model, tst_scores, scale=scale)
			
			# now fill in the values
			res_df["val_auc"], res_df["val_auprc"], res_df["val_tpr_5"], res_df["val_f1_5"] = 
				basic_stats(val_y, val_probs)
			res_df["tst_auc"], res_df["tst_auprc"], res_df["tst_tpr_5"], res_df["tst_f1_5"] = 
				basic_stats(tst_y, tst_probs)
		else
			res_df["val_auc"], res_df["val_auprc"], res_df["val_tpr_5"], res_df["val_f1_5"] = 
				NaN, NaN, NaN, NaN
			res_df["tst_auc"], res_df["tst_auprc"], res_df["tst_tpr_5"], res_df["tst_f1_5"] = 
				NaN, NaN, NaN, NaN
		end

		# then do the same on a small section of the data
		ps = [100.0, 50.0, 20.0, 10.0, 5.0, 2.0, 1.0, 0.5, 0.2, 0.1]
		auc_ano_100 = [perf_at_p_agg(p/100, 1.0, val_scores, val_y, tst_scores, tst_y, init_alpha, 
            alpha0, base_beta; scale=scale) for p in ps]
		for (k,v) in zip(map(x->x * "_100", AUC_METRICS), auc_ano_100)
			res_df["val_"*k] = v[1]
			res_df["tst_"*k] = v[2]
		end

		res_df
	end
	
	# then save it
	res_df = DataFrame(res_df)
	save(outf, Dict(:df => res_df))
	@info "Saved $outf."
	res_df
end

function basic_experiment(val_scores, val_y, tst_scores, tst_y, outf, dataset, data, seed, ac)
	# setup params
	parameters = data[:parameters]

	res_df = OrderedDict()
	res_df["modelname"] = modelname
	res_df["dataset"] = dataset
	res_df["phash"] = GenerativeAD.Evaluation.hash(parameters)
	res_df["parameters"] = "_"*savename(parameters)
	res_df["fit_t"] = NaN
	res_df["tr_eval_t"] = NaN
	res_df["val_eval_t"] = NaN
	res_df["tst_eval_t"] = NaN
	res_df["seed"] = seed
	res_df["npars"] = NaN
	res_df["anomaly_class"] = ac
	res_df["method"] = nothing
	res_df["score_type"] = nothing
	res_df["latent_score_type"] = nothing

	# first, filter out NaNs and Infs
	inds = val_scores .!= Inf
	val_scores = val_scores[inds]
	val_y = val_y[inds]
	inds =  .! isnan.(val_scores)
	val_scores = val_scores[inds]
	val_y = val_y[inds]

	# now fill in the values
	res_df["val_auc"], res_df["val_auprc"], res_df["val_tpr_5"], res_df["val_f1_5"] = 
		basic_stats(val_y, val_scores)
	res_df["tst_auc"], res_df["tst_auprc"], res_df["tst_tpr_5"], res_df["tst_f1_5"] = 
		basic_stats(tst_y, tst_scores)

	# then do the same on a small section of the data
	ps = [100.0, 50.0, 20.0, 10.0, 5.0, 2.0, 1.0, 0.5, 0.2, 0.1]
	auc_ano_100 = [perf_at_p_basic_agg(p/100, 1.0, val_scores, val_y, tst_scores, tst_y) for p in ps]
	for (k,v) in zip(map(x->x * "_100", AUC_METRICS), auc_ano_100)
		res_df["val_"*k] = v[1]
		res_df["tst_"*k] = v[2]
	end

	# then save it
	res_df = DataFrame(res_df)
	save(outf, Dict(:df => res_df))
	@info "Saved $outf."
	res_df
end

# for sgvaegan alpha
function compute_alphas(scores, labels)
	n = size(scores,2)
    # first determine which is the most important base score
    base_aucs = map(i->auc_val(labels, scores[:,i]), 1:(n-3))
    ibest = argmax(base_aucs)
    
    # create the robust logistic regression
    init_alpha = ones(Float32, n)*0.1
    alpha0 = zeros(Float32, n)
    init_alpha[ibest] = 1.0
    alpha0[ibest] = 1.0
    init_alpha, alpha0
end