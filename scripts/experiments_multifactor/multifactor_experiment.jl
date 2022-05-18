using DrWatson
@quickactivate
using GenerativeAD
using ArgParse

s = ArgParseSettings()
@add_arg_table! s begin
	"modelname"
        default = "vae"
		arg_type = String
		help = "model name"
    "train_class"
        default = 1
        help = "set the anomaly class to be computed"
    "dataset"
        default = "wildlife_MNIST"
        arg_type = String
        help = "dataset"
    "--anomaly_factors"
        arg_type = Int
        nargs = '+'
        help = "set one or more anomalous factors"
    "--force", "-f"
        action = :store_true
        help = "force recomputing of scores"
end
parsed_args = parse_args(ARGS, s)
@unpack modelname, dataset, train_class, anomaly_factors, force = parsed_args
method = "leave-one-in"
seed = 1
nf = length(anomaly_factors)
(nf == 0 || nf > 3) ? error("number of --anomaly_factors must be between 1 and 3") : nothing

# anomaly factors to strings and back
_afs2str(x) = reduce((a,b)->"$(a)$(b)", x)
_str2afs(x) = map(i->Meta.parse(string(x[i])), 1:length(x))
afstring =  _afs2str(anomaly_factors)

function experiment(sf, score_dir, save_dir, modelname, dataset, seed, train_class, anomaly_factors, afstring)
    # first check if we need to do anything
    target = joinpath(save_dir, "eval_$(basename(sf))")
    if isfile(target) && !force
        @info "$target already present, skipping"    
        return
    end
    isfile(target) ? rm(target) : nothing

    # val and tst scores are only scores of normal samples
    sdata = load(joinpath(score_dir, sf))
    val_scores_orig, tst_scores_orig, mf_scores = sdata[:val_scores], sdata[:tst_scores], sdata[:mf_scores]
    mf_labels = sdata[:mf_labels]

    # split them (pseudo)randomly
    (val_scores, val_labels), (tst_scores, tst_labels) = GenerativeAD.Datasets.split_multifactor_data(
        anomaly_factors, train_class, (val_scores_orig, tst_scores_orig), mf_scores, mf_labels; 
        use_mf_anomalies=false, seed=seed)

    # make the correct input for the next function
    res_dict = Dict(
        :modelname => modelname,
        :dataset => dataset,
        :parameters => merge(sdata[:parameters], (anomaly_factors = afstring,)),
        :fit_t => NaN,
        :tr_eval_t => NaN,
        :tst_eval_t => NaN,
        :val_eval_t => NaN,
        :seed => sdata[:seed],
        :npars => sdata[:npars],
        :anomaly_class => sdata[:anomaly_class],
        :val_scores => val_scores,
        :val_labels => val_labels,
        :tst_scores => tst_scores,
        :tst_labels => tst_labels,
        )
        
    # this contains the scores
    df = GenerativeAD.Evaluation.compute_stats(res_dict; top_metrics=false, top_metrics_new=true)
    wsave(target, Dict(:df => df))
    @info "saved evaluation at $target"
end

# save dir
save_dir = datadir("experiments_multifactor/evaluation/$(modelname)/$(dataset)/ac=$(train_class)/seed=$(seed)/af=$(afstring)")
mkpath(save_dir)

# then load the requested scores
score_dir = datadir("experiments_multifactor/base_scores/$(modelname)/$(dataset)/ac=$(train_class)/seed=$(seed)")
sfs = readdir(score_dir)

for sf in sfs
    experiment(sf, score_dir, save_dir, modelname, dataset, seed, train_class, anomaly_factors, afstring)
end