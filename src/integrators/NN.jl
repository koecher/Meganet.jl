export NN,getNN,initTheta
# using TimerOutputs
# to = TimerOutput()
"""
NN Neural Network block

 Y_k+1 = layer{k}(theta{k},Y_k)
"""
mutable struct NN{T, TQ <: Union{Array{T,2},UniformScaling{Int}}} <: AbstractMeganetElement{T}
    layers   ::Array{AbstractMeganetElement{T}, 1} # layers of Neural Network, cell array
    outTimes ::Array{Int,1}
    Q        :: TQ
end

function getNN(layers::Array{AbstractMeganetElement{T}},outTimes=eye(Int,length(layers))[:,end],Q=I) where {T <: Number}
	nt   = length(layers)
    nout = nFeatOut(layers[1])

    for k=2:nt
        if nFeatIn(layers[k]) != nout
            error("Dim. of input features of block $k does not match dim. of output features of block $(k-1)");
        end
        nout = nFeatOut(layers[k])
    end
	return NN(layers,outTimes,Q);
end


import Base.display
function display(this::NN)
    println("-- Neural Network --")
    println("nLayers: \t $(length(this.layers))")
    println("nFeatIn: \t $(nFeatIn(this))")
    println("nFeatOut: \t $(nFeatOut(this))")
    println("nTheta: \t $(nTheta(this))")
end

# ---------- counting thetas, input and output features -----
function nTheta(this::NN)
    n::Int = 0;
    for k=1:length(this.layers)
        n += nTheta(this.layers[k]);
    end
    return n
end
nFeatIn(this::NN)   = nFeatIn(this.layers[1])
nFeatOut(this::NN)::Int = nFeatOut(this.layers[end])

function nDataOut(this::NN)
    n=0;
    for k=1:length(this.layers)
        n = n+this.outTimes[k]* nFeatOut(this.layers[k]);
    end
end

function initTheta(this::NN{T}) where {T <: Number}
    theta = zeros(T,0)
    for k=1:length(this.layers)
        theta = [theta; vec(initTheta(this.layers[k]))]
    end
    return convert(Array{T},theta)
end


# --------- forward problem ----------
function apply(this::NN{T},theta::Array{T},Y::Array{T,2},tmp,doDerivative=true) where {T<:Number}

    nex = div(length(Y),nFeatIn(this))::Int
    nt = length(this.layers)

    if isempty(tmp) #TODO Will have to make sure size of Y doesnt change
        tmp = Array{Any}(nt+1,2)
    end

    if doDerivative
        if isassigned(tmp,1,1)
            #tmp[1,1] .= Y This does not work, need to hack like below :)
            tmp11 = tmp[1,1]
            tmp11 .= Y
        else
            tmp[1,1] = copy(Y)
        end
    end

    Ydata::Array{T,2} = zeros(T,0,nex)
    cnt = 0
    for i=1:nt
        ni = nTheta(this.layers[i])::Int
        if !isassigned(tmp,i,2)
            tmp[i,2] = Array{Any}(0)
        end
        Yd::Array{T,2}, Y, tmp[i,2] = apply(this.layers[i],theta[cnt+(1:ni)],Y,tmp[i,2],doDerivative)

        if this.outTimes[i]==1
            Ydata = [Ydata; this.Q*Yd]
        end
        if doDerivative
            if isassigned(tmp,i+1,1)
                tmp1 = tmp[i+1,1]
                tmp1 .= Y
            else
                tmp[i+1,1] = copy(Y)
            end
        end
        cnt = cnt + ni
    end
    return Ydata,Y,tmp
end

# -------- Jacobian matvecs --------
function JYmv(this::NN{T},dY::Array{T},theta::Array{T},Y::Array{T},tmp) where {T <: Number}
    nex = div(length(Y),nFeatIn(this))
    nt = length(this.layers)
    cnt = 0
    dYdata = zeros(T,0,nex)
    for i=1:nt
        ni = nTheta(this.layers[i])
        dY = JYmv(this.layers[i],dY,theta[cnt+(1:ni)],tmp[i,1],tmp[i,2])[2]
        if this.outTimes[i]==1
            dYdata = [dYdata; this.Q*dY]
        end
        cnt = cnt+ni
    end
    return dYdata, dY
end

function  Jmv(this::NN{T},dtheta::Array{T},dY::Array{T},theta::Array{T},Y::Array{T},tmp) where {T <: Number}
    nex = div(length(Y),nFeatIn(this))
    nt = length(this.layers);
    if isempty(dY)
        dY = 0*Y
    end

    dYdata = zeros(T,0,nex)
    cnt = 0
    for i=1:nt
        ni = nTheta(this.layers[i])
        dY = Jmv(this.layers[i],dtheta[cnt+(1:ni)],dY,theta[cnt+(1:ni)],
                tmp[i,1],tmp[i,2])[2]
        if this.outTimes[i]==1
            dYdata = [dYdata; this.Q*dY]
        end
        cnt = cnt+ni
    end
    return dYdata,dY
end

# -------- Jacobian' matvecs --------
function JYTmv(this::NN{T},Wdata::Array{T},W::Array{T},theta::Array{T},Y::Array{T},tmp) where {T <: Number}

    nex = div(length(Y),nFeatIn(this));
    if !isempty(Wdata)
        Wdata = reshape(Wdata,:,nex);
    end
    if isempty(W)
        W = zero(T)
    elseif length(W)>1
        W     = reshape(W,:,nex)
    end
    nt = length(this.layers)

    cnt = 0; cnt2 = 0;
    for i=nt:-1:1
        ni = nTheta(this.layers[i])
        if this.outTimes[i]==1
            nn = nFeatOut(this.layers[i])
            W = W + this.Q'*Wdata[end-cnt2-nn+1:end-cnt2,:]
            cnt2 = cnt2 + nn
        end
        W  = JYTmv(this.layers[i], W,(T)[],theta[end-cnt-ni+1:end-cnt],
                    tmp[i,1],tmp[i,2])
        cnt = cnt+ni
    end
    return W
end


function JthetaTmv(this::NN{T},Wdata::Array{T},W::Array{T},theta::Array{T},Y::Array{T},tmp) where {T <: Number}
	return JTmv(this,Wdata,W,theta,Y,tmp)[1]; # TODO: Why calculating both, Can be more efficient?
end



function JTmv(this::NN{T},Wdata::Array{T},Win::Array{T},theta::Array{T},Y::Array{T},tmp)::Tuple{Array{T,1},Array{T,1}} where {T <: Number}
    # WOW THIS IS HACKED BIG TIME. Need to find a way to type stabalize W (not ez)
    #TODO: Make this type stable - Some internals are not stable
    nex = div(length(Y),nFeatIn(this)::Int)

    if size(Wdata,1)>0
        Wdata = reshape(Wdata,:,nex)
    end

    if length(Win)==0
        W = zeros(T,nFeatOut(this),nex)
    else
        W = reshape(Win,:,nex)
    end
    dtheta = zero(T)*theta
    nt = length(this.layers)

    cnt = 0; cnt2 = 0
    for i=nt:-1:1
        if this.outTimes[i]==1
            nn = nFeatOut(this.layers[i])::Int
            W += this.Q'*Wdata[end-cnt2-nn+1:end-cnt2,:]
            cnt2 = cnt2 + nn
        end
        ni     = nTheta(this.layers[i])::Int

        dmbi,W = JTmv(this.layers[i],W,zeros(T,0),theta[end-cnt-ni+1:end-cnt],tmp[i,1],tmp[i,2])
        dtheta[end-cnt-ni+1:end-cnt]  = dmbi
        cnt += ni
    end

    return  vec(dtheta), vec(W)
end
