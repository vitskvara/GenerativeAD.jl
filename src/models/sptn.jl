using Flux
using StatsBase
using Statistics
using Distributions
using DistributionsAD
using SumProductTransform

struct SPTN
	m
end

Flux.@functor SPTN

function SPTN(;idim::Int=1, zdim::Int=1, activation=identity, ncomp=4, nlayers::Int=2, 
							init_seed=nothing, unitary=:butterfly, sharing=:dense, firstdense=false, kwargs...)
	# if seed is given, set it
	(init_seed != nothing) ? Random.seed!(init_seed) : nothing

	model = SumProductTransform.buildmixture(
				idim, 
				ncomp, 
				nlayers, 
				activation; 
				sharing = sharing, 
				firstdense = firstdense, 
				unitary = unitary)

	# reset seed
	(init_seed != nothing) ? Random.seed!() : nothing

	SPTN(model)
end

function Base.show(io::IO, sptn::SPTN)
	# to avoid the show explosion
	print(io, "SPTN(...)")
end

function StatsBase.predict(model::SPTN, x)
	-logpdf(model.m, x)
end

function StatsBase.fit!(model::SPTN, data::Tuple; max_train_time=82800,
						batchsize=64, patience=30, check_interval::Int=10, kwargs...)
	opt = ADAM()
	history = MVHistory()
	tr_model = deepcopy(model)
	ps = Flux.params(tr_model)
	_patience = patience

	# split data
	tr_x = data[1][1]
	val_x = data[2][1][:, data[2][2] .== 0]
		
	best_val_loss = Inf
	i = 1
	start_time = time()
	val_lkl_time = 0.0
	train_time = 0.0
	frmt = (v) -> round(v, digits=4)
	for batch in RandomBatches(tr_x, batchsize)
		# batch loss
		batch_loss = 0f0
		train_time += @elapsed begin
			gs = gradient(() -> begin 
				batch_loss = -mean(logpdf(tr_model.m, batch))
			end, ps)
			Flux.update!(opt, ps, gs)
		end

		# validation/early stopping
		val_lkl_time += @elapsed val_loss = -mean(batchlogpdf(tr_model.m, val_x, batchsize))
		
		if (i%check_interval == 0) 
			@info "$i - loss: $(frmt(batch_loss)) (batch) | $(frmt(val_loss)) (validation) || $(frmt(train_time/i)) (t_grad) | $(frmt(val_lkl_time/i)) (t_val)")
		end

		if isnan(val_loss) || isnan(batch_loss)
			error("Encountered invalid values in loss function.")
		end

		push!(history, :training_loss, i, batch_loss)
		push!(history, :validation_likelihood, i, val_loss)
			
		if val_loss < best_val_loss
			best_val_loss = val_loss
			_patience = patience

			# this should save the model at least once
			# when the validation loss is decreasing 
			if mod(i, 10) == 0
				model = deepcopy(tr_model)
			end
		elseif time() - start_time > max_train_time # stop early if time is running out
			model = deepcopy(tr_model)
			@info "Stopped training after $(i) iterations, $((time() - start_time)/3600) hours."
			break
		else # else stop if the model has not improved for `patience` iterations
			_patience -= 1
			if _patience == 0
				@info "Stopped training after $(i) iterations, $((time() - start_time)/3600) hours."
				break
			end
		end
		i += 1
	end
	
	(history=history, iterations=i, grad_time=train_time/i, val_time=val_lkl_time/i, model=model, npars=sum(map(p -> length(p), ps)))
end
