export SGD, solve, getSGDsolver, solve_local

"""
Stochastic Gradient Descent
"""
mutable struct SGD{T}
    maxEpochs::Int
    miniBatch::Int
    out::Bool
    learningRate::T
    momentum::T
    nesterov::Bool
	ADAM::Bool
end

function getSGDsolver(TYPE::Type ;maxEpochs=10,miniBatch=16,out=true,learningRate=0.1,momentum=0.9,nesterov=false,ADAM=false)
	if ADAM && nesterov
		warn("sgd(): ADAM and nestrov together - choosing ADAM");
		nesterov  = false;
	end
	return SGD{TYPE}(maxEpochs,miniBatch,out,convert(TYPE,learningRate),convert(TYPE,momentum), nesterov, ADAM)
end



Base.display(this::SGD)=println("SGD(maxEpochs=$(this.maxEpochs),miniBatch=$(this.miniBatch),learningRate=$(this.learningRate),momentum=$(this.momentum),nesterov=$(this.nesterov),ADAM=$(this.ADAM))")

function solve(this::SGD{T},objFun::dnnObjFctn,xc::Array{T},Y::Array{T},C::Array{T},Yv::Array{T},Cv::Array{T}) where {T}

    global XC
    XC = xc

    # evaluate training and validation
    epoch = 1
    xOld = copy(xc)
    dJ = zeros(T,size(xc))
    mJ = zeros(T,size(xc))
    vJ = zeros(T,size(xc))
    beta2 = convert(T,0.999)
    beta1 = this.momentum
    lr    = this.learningRate

    this.out && display(this)

    # Distribute the data
    nw = nworkers()
    Ys = SharedArray(Y)
    Cs = SharedArray(C)
    println("Using $(nw) workers...")

    while epoch <= this.maxEpochs
        tic()
        # Train on all workers
        #@sync for pid in Ys.pids
        #    @async @fetchfrom pid train(this, objFun, xc, Ys, Cs, beta1, beta2)
        #end
        for pid in Ys.pids
            @fetchfrom pid train(this, objFun, xc, Ys, Cs, beta1, beta2)
        end

        # we sample 2^12 images from the training set for displaying the objective.
        xc = Meganet.XC
        nex = size(Y,2)
        n_total = min(nex,60)
        n_worker = div(n_total, nw)

        JcA     = Array{T,1}(nw)
        hisFA    = Array{Array{T,1},1}(nw)
        Jval = zero(T)
        pVal = Array{T,1}()
	    tmp = Array{Any}(0,0)

        @sync begin
                for (i, pid) in enumerate(Ys.pids)
                    @async JcA[i], hisFA[i] = @fetchfrom pid evalObjFctn_local(objFun, xc, Ys, Cs, n_worker)
                end

                # Currently validation data is on master so this is local
                @async Jval,pVal = @fetchfrom 1 getMisfit(objFun,xc,Yv,Cv,tmp, false);
        end

        Jc = sum(JcA)
        hisF = sum(hisFA)

        if this.out;
            @printf "%d\t%1.2e\t%1.2f\t%1.2e\t%1.2e\t%1.2f\n" epoch Jc 100*(1-hisF[3]/hisF[2]) norm(xOld-xc) Jval 100*(1-pVal[3]/pVal[2])
        end

        xOld   = copy(xc);
        epoch += 1
        toc()
    end

    return xc
end

"""
    Use: evalObjFctn_local(objFun, xc, Y, C, n)

Evaluate the objective function on `n` random examples from `Y`
"""
function evalObjFctn_local(objFun::dnnObjFctn, xc::Array{T,1}, Y::SharedArray{T,2}, C::SharedArray{T,2}, n::Int) where {T<:Number}

    nex = size(Y,2)
    ids = randperm(nex)
    idt = ids[1:min(n, nex)]
    tmp = Array{Any}(0,0)

    Jc, hisF, dJ = evalObjFctn(objFun,xc,Y[:,idt], C[:,idt], tmp, false);

    return Jc, hisF, dJ
end

"""
Train on the local part of the distributed data in Y
"""
function train(this::SGD{T}, objFun::dnnObjFctn, xc::Array{T,1}, Y::SharedArray{T,2}, C::SharedArray{T,2}, beta1::T, beta2::T) where {T<:Number}
# TODO send the worker SGD and objFun onl once

    nex = size(Y,2)
    nworkers = length(Y.pids)
    ids = randperm(nex)
    lr = this.learningRate
    #lr = this.learningRate*nworkers
    dJ = zeros(T,size(xc))
    tmp = Array{Any}(0,0)

    batchsize = div(this.miniBatch, nworkers)

    for k=1:ceil(Int64,nex/this.miniBatch)
        idk = ids[(k-1)*batchsize+1: min(k*batchsize,nex)]
        if this.nesterov && !this.ADAM
            Jk,dummy,dJk = evalObjFctn(objFun, xc-this.momentum*dJ, Y[:,idk], C[:,idk], tmp);
        else
            Jk,dummy,dJk = evalObjFctn(objFun, xc, Y[:,idk], C[:,idk], tmp);
        end

        if this.ADAM
           mJ = beta1*mJ + (one(T)-beta1)*(dJk)
           vJ = beta2*vJ + (one(T)-beta2)*(dJk.^2)
        else
           dJ = lr*dJk + this.momentum*dJ
        end
        #xc = xc - dJ

        # Exchange weights
        update = Future(1)
        put!(update, dJ)
        xc = @fetchfrom 1 update_weights!(Meganet.XC, update)
    end

    return nothing
end

function update_weights!(xc::Vector{<:Number}, update::Future)
    println("Derivative received from :$(update.whence)")
    dJ = fetch(update)
    xc .= xc .- dJ

    return xc
end
