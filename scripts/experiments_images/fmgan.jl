using DrWatson
@quickactivate
using ArgParse
using GenerativeAD
import StatsBase: fit!, predict
using StatsBase
using BSON
using Flux
using GenerativeModels

s = ArgParseSettings()
@add_arg_table! s begin
   "max_seed"
		default = 1
		arg_type = Int
		help = "seed"
	"dataset"
		default = "MNIST"
		arg_type = String
		help = "dataset"
	"anomaly_classes"
		arg_type = Int
		default = 10
		help = "number of anomaly classes"
	"method"
		arg_type = String
		default = "leave-one-out"
		help = "method for data creation -> \"leave-one-out\" or \"leave-one-in\" "
    "contamination"
    	arg_type = Float64
    	help = "contamination rate of training data"
    	default = 0.0
end
parsed_args = parse_args(ARGS, s)
@unpack dataset, max_seed, anomaly_classes, method, contamination = parsed_args

#######################################################################################
################ THIS PART IS TO BE PROVIDED FOR EACH MODEL SEPARATELY ################

modelname = "fmgan"


# sample parameters, should return a Dict of model kwargs 
"""
	sample_params()

Should return a named tuple that contains a sample of model parameters.
"""
function sample_params()
	# first sample the number of layers
	nlayers = rand(2:4)
	kernelsizes = reverse((3,5,7,9)[1:nlayers])
	channels = reverse((16,32,64,128)[1:nlayers])
	scalings = reverse((1,2,2,2)[1:nlayers])
	
	par_vec = (2 .^(3:8), 10f0 .^(-4:-3), 2 .^ (5:7), ["relu", "swish", "tanh"], 1:Int(1e8), 10f0 .^ (-3:3))
	argnames = (:zdim, :lr, :batchsize, :activation, :init_seed, :alpha,)
	parameters = (;zip(argnames, map(x->sample(x, 1)[1], par_vec))...)
	return merge(parameters, (nlayers=nlayers, kernelsizes=kernelsizes,
		channels=channels, scalings=scalings))
end
batch_score(scoref, model, x, batchsize=512) =
	vcat(map(y->vec(cpu(scoref(model, gpu(Array(y))))), Flux.Data.DataLoader(x, batchsize=batchsize))...)
"""
	fit(data, parameters)

This is the most important function - returns `training_info` and a tuple or a vector of tuples `(score_fun, final_parameters)`.
`training_info` contains additional information on the training process that should be saved, the same for all anomaly score functions.
Each element of the return vector contains a specific anomaly score function - there can be multiple for each trained model.
Final parameters is a named tuple of names and parameter values that are used for creation of the savefile name.
"""
function fit(data, parameters)
	# construct model - constructor should only accept kwargs
	idim = size(data[1][1])[1:3]

	# construct model - constructor should only accept kwargs
	model = GenerativeAD.Models.conv_gan_constructor(;idim=idim, parameters...) |> gpu
	
	# setup the loss functions
	function gloss(m, x)
		# move x to gpu
		x = gpu(Array(x))
		z = gpu(rand(cpu(m.prior), size(x,ndims(x))))

			# generator loss
		gl = GenerativeAD.Models.gloss(m.discriminator.mapping,
			      m.generator.mapping,z)

		# fm loss
		h = m.discriminator.mapping[1:end-3]
		hx = h(x)
		hz = h(m.generator.mapping(z))
		fml = Flux.mse(hx, hz)

		parameters.alpha*gl + fml
	end
	gloss(m, x, batchsize::Int) =
			mean(map(y->gloss(m,y), Flux.Data.DataLoader(x, batchsize=batchsize)))
	function dloss(m, x)
		x = gpu(Array(x))
		z = gpu(rand(cpu(m.prior), size(x,ndims(x))))
			GenerativeAD.Models.dloss(m.discriminator.mapping,m.generator.mapping,x,z)
	end
	dloss(m, x, batchsize::Int) =
		mean(map(y->dloss(m,y), Flux.Data.DataLoader(x, batchsize=batchsize)))

	# set number of max iterations apropriately
	max_iter = 5000 # this should be enough

	# fit train data
	try
		global info, fit_t, _, _, _ = @timed fit!(model, data, gloss, dloss; max_iters=10000,
			max_train_time=23*3600/max_seed/anomaly_classes/4, patience=200, 
			check_interval=10,
			usegpu=true, parameters...)
	catch e
		# return an empty array if fit fails so nothing is computed
		@info "Failed training due to \n$e"
		return (fit_t = NaN, history=nothing, npars=nothing, model=nothing), [] 
	end
	model = info.model
	
	# construct return information - put e.g. the model structure here for generative models
	training_info = (
		fit_t = fit_t,
		history = info.history,
		npars = info.npars,
		model = model |> cpu
		)

	# now return the different scoring functions
	training_info, [
		(x -> 1f0 .- batch_score(GenerativeAD.Models.discriminate, model, x), parameters)
		]
end

####################################################################
################ THIS PART IS COMMON FOR ALL MODELS ################
# only execute this if run directly - so it can be included in other files
if abspath(PROGRAM_FILE) == @__FILE__
	# set a maximum for parameter sampling retries
	try_counter = 0
	max_tries = 10*max_seed
	cont_string = (contamination == 0.0) ? "" : "_contamination-$contamination"
	while try_counter < max_tries
		parameters = sample_params()

		for seed in 1:max_seed
			for i in 1:anomaly_classes
				savepath = datadir("experiments/images_$(method)$cont_string/$(modelname)/$(dataset)/ac=$(i)/seed=$(seed)")
				mkpath(savepath)

				# get data
				data = GenerativeAD.load_data(dataset, seed=seed, anomaly_class_ind=i, method=method, contamination=contamination)
				
				# edit parameters
				edited_parameters = GenerativeAD.edit_params(data, parameters)

				@info "Trying to fit $modelname on $dataset with parameters $(edited_parameters)..."
				@info "Train/validation/test splits: $(size(data[1][1], 4)) | $(size(data[2][1], 4)) | $(size(data[3][1], 4))"
				@info "Number of features: $(size(data[1][1])[1:3])"

				# check if a combination of parameters and seed alread exists
				if GenerativeAD.check_params(savepath, edited_parameters)
					# fit
					training_info, results = fit(data, edited_parameters)

					# save the model separately			
					if training_info.model != nothing
						tagsave(joinpath(savepath, savename("model", edited_parameters, "bson", digits=5)), 
							Dict("model"=>training_info.model,
								 "fit_t"=>training_info.fit_t,
								 "history"=>training_info.history,
								 "parameters"=>edited_parameters
								 ), 
							safe = true)
						training_info = merge(training_info, 
							(model=nothing,))
					end

					# here define what additional info should be saved together with parameters, scores, labels and predict times
					save_entries = merge(training_info, (modelname = modelname, seed = seed, dataset = dataset, anomaly_class = i,
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
	end
	(try_counter == max_tries) ? (@info "Reached $(max_tries) tries, giving up.") : nothing
end
