using DrWatson
@quickactivate
using ArgParse
using GenerativeAD
import StatsBase: fit!, predict
using StatsBase
using BSON
using Flux

s = ArgParseSettings()
@add_arg_table! s begin
    "max_seed"
        default = 1
        arg_type = Int
        help = "max_seed"
    "category"
        default = "wood"
        arg_type = String
        help = "dataset"
    "contamination"
        arg_type = Float64
        help = "contamination rate of training data"
        default = 0.0
end
parsed_args = parse_args(ARGS, s)
@unpack category, max_seed, contamination = parsed_args
cont_string = (contamination == 0.0) ? "" : "_contamination-$contamination"

#######################################################################################
################ THIS PART IS TO BE PROVIDED FOR EACH MODEL SEPARATELY ################
modelname = "cgn"
# sample parameters, should return a Dict of model kwargs 
"""
    sample_params()

Should return a named tuple that contains a sample of model parameters.
"""
function sample_params()
    par_vec = (2 .^(3:8), 2 .^(3:6), 2 .^(3:6), 2 .^(3:5), ["orthogonal", "kaiming", "xavier", "normal"], 
        0.01:0.01:0.1, 1:Int(1e8), 0.1:0.2:1,  10f0 .^(-4:0.1:-3))
    argnames = (:z_dim, :h_channels, :disc_h_dim, :batch_size, :init_type, 
        :init_gain, :init_seed, :lambda_mask, :lr)
    parameters = (;zip(argnames, map(x->sample(x, 1)[1], par_vec))...)
end
function GenerativeAD.edit_params(data, parameters)
    idim = size(data[1][1])
    parameters = merge(parameters, (img_dim=idim[1],))
    parameters
end
    
"""
    fit(data, parameters)

This is the most important function - returns `training_info` and a tuple or a vector of tuples `(score_fun, final_parameters)`.
`training_info` contains additional information on the training process that should be saved, the same for all anomaly score functions.
Each element of the return vector contains a specific anomaly score function - there can be multiple for each trained model.
Final parameters is a named tuple of names and parameter values that are used for creation of the savefile name.
"""
function fit(data, parameters, seed)
    # construct model - constructor should only accept kwargs
    model = GenerativeAD.Models.CGNAnomaly(;parameters...)

    # save intermediate results here
    res_save_path = datadir("sgad_models/images_mvtec$cont_string/$(modelname)/$(category)/ac=1/seed=$(seed)/model_id=$(parameters.init_seed)")
    mkpath(res_save_path)

    # fit train data
    n_epochs = 1000
    epoch_iters = ceil(Int, length(data[1][2])/parameters.batch_size)
    save_iter = epoch_iters*Int(n_epochs/5)
    try
         global info, fit_t, _, _, _ = @timed fit!(model, data[1][1]; 
            max_train_time=20*3600/max_seed, workers=4,
            n_epochs = n_epochs, save_iter = save_iter, save_results = true, save_path = res_save_path)
    catch e
        # return an empty array if fit fails so nothing is computed
        @info "Failed training due to \n$e"
        return (fit_t = NaN, history=nothing, npars=nothing, model=nothing), [] 
    end
    
    # construct return information - put e.g. the model structure here for generative models
    training_info = (
        fit_t = fit_t,
        history = info.history,
        npars = info.npars,
        model = model,
        best_epoch = info.best_epoch,
        tr_encodings = nothing,
        val_encodings = nothing,
        tst_encodings = nothing
        )

    # save the final model
    max_iters = length(info.history["iter"])
    training_info.model.model.save_weights(
        joinpath(joinpath(res_save_path, "weights"), "cgn_$(max_iters).pth"),
        joinpath(joinpath(res_save_path, "weights"), "discriminator_$(max_iters).pth")
        )

    # now return the different scoring functions
    training_info, [
        (x-> predict(model, x, score_type="discriminator", workers=4), merge(parameters, (score = "discriminator",))),
        (x-> predict(model, x, score_type="perceptual", workers=4), merge(parameters, (score = "perceptual",)))
        ]
end

####################################################################
################ THIS PART IS COMMON FOR ALL MODELS ################
# only execute this if run directly - so it can be included in other files
if abspath(PROGRAM_FILE) == @__FILE__
    # set a maximum for parameter sampling retries
    try_counter = 0
    max_tries = 10*max_seed
    while try_counter < max_tries
        parameters = sample_params()

        for seed in 1:max_seed
            savepath = datadir("experiments/images_mvtec$(cont_string)/$(modelname)/$(category)/ac=1/seed=$(seed)")
            mkpath(savepath)

            # get data
            data = GenerativeAD.load_data("MVTec-AD", seed=seed, category=category, 
                contamination=contamination, img_size=128)
            
            # edit parameters
            edited_parameters = GenerativeAD.edit_params(data, parameters)

            @info "Trying to fit $modelname on $category with parameters $(edited_parameters)..."
            @info "Train/validation/test splits: $(size(data[1][1], 4)) | $(size(data[2][1], 4)) | $(size(data[3][1], 4))"
            @info "Number of features: $(size(data[1][1])[1:3])"

            # check if a combination of parameters and seed alread exists
            if GenerativeAD.check_params(savepath, edited_parameters)
                # fit
                training_info, results = fit(data, edited_parameters, seed)

                # save the model separately         
                if training_info.model !== nothing
                    tagsave(joinpath(savepath, savename("model", edited_parameters, "bson", digits=5)), 
                        Dict("fit_t"=>training_info.fit_t,
                             "history"=>training_info.history,
                             "parameters"=>edited_parameters,
                             "tr_encodings"=>training_info.tr_encodings,
                             "val_encodings"=>training_info.val_encodings,
                             "tst_encodings"=>training_info.tst_encodings,
                             ), 
                        safe = true)
                    training_info = merge(training_info, 
                        (model=nothing,tr_encodings=nothing,val_encodings=nothing,tst_encodings=nothing))
                end

                # here define what additional info should be saved together with parameters, scores, labels and predict times
                save_entries = merge(training_info, (modelname = modelname, seed = seed, 
                    category = category, dataset = "MVTec-AD_$category",
                    contamination=contamination))

                # now loop over all anomaly score funs
                for result in results
                    GenerativeAD.experiment(result..., data, savepath; save_entries...)
                end
                global try_counter = max_tries + 1
            else
                @info "Model already present, trying new hyperparameters..."
                global try_counter += 1
            end
        end
    end
    (try_counter == max_tries) ? (@info "Reached $(max_tries) tries, giving up.") : nothing
end
