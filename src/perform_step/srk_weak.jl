
@muladd function perform_step!(integrator,cache::DRI1ConstantCache,f=integrator.f)
  @unpack a021,a031,a032,a121,a131,b021,b031,b121,b131,b221,b222,b223,b231,b232,b233,α1,α2,α3,c02,c03,c12,c13,beta11,beta12,beta13,beta22,beta23,beta31,beta32,beta33,beta42,beta43,NORMAL_ONESIX_QUANTILE = cache
  @unpack t,dt,uprev,u,W,p = integrator

  # define three-point distributed random variables
  dW_scaled = W.dW / sqrt(dt)
  _dW = map(x -> calc_threepoint_random(integrator, NORMAL_ONESIX_QUANTILE, x), dW_scaled)
  chi1 = map(x -> (x^2-dt)/2, _dW) # diagonal of Ihat2
  if !(typeof(W.dW) <: Number)
    m = length(W.dW)
    # define two-point distributed random variables
    _dZ = map(x -> calc_twopoint_random(integrator, x),  W.dZ)
    Ihat2 = zeros(eltype(W.dZ), m, m) # I^_(k,l)
    for k = 1:m
      for l = 1:m
        if k<l
          Ihat2[k, l] = (_dW[k]*_dW[l]-integrator.sqdt*_dZ[k])/2
        elseif l<k
          Ihat2[k, l] = (_dW[k]*_dW[l]+integrator.sqdt*_dZ[l])/2
        else k==l
          Ihat2[k, k] = chi1[k]
        end
      end
    end
  end

  # compute stage values
  k1 = integrator.f(uprev,p,t)
  g1 = integrator.g(uprev,p,t)

  # H_i^(0), stage 1
  # H01 = uprev
  # H_i^(0), stage 2
  if !is_diagonal_noise(integrator.sol.prob) || typeof(W.dW) <: Number
    H02 = uprev + a021*k1*dt + b021*g1*_dW
  else
    H02 = uprev + a021*k1*dt + b021*g1.*_dW
  end

  # H_i^(0), stage 3 (requires H_i^(k) stage 2 in general)
  k2 = integrator.f(H02,p,t+c02*dt)
  H03 = uprev + a032*k2*dt + a031*k1*dt
  if !is_diagonal_noise(integrator.sol.prob) || typeof(W.dW) <: Number
    H03 += b031*g1*_dW
  else
    H03 += b031*g1.*_dW
  end

  k3 = integrator.f(H03,p,t+c03*dt)

  # H_i^(k), stage 1
  # H11 = uprev
  # H_i^(k), stage 2
  if typeof(W.dW) <: Number
    H12 = uprev + a121*k1*dt + b121*g1*integrator.sqdt
  elseif is_diagonal_noise(integrator.sol.prob)
    H12 = Vector{typeof(uprev)}[uprev .+ a121*k1*dt .+ b121*g1[k]*integrator.sqdt for k=1:m]
  else
    H12 = Vector{typeof(uprev)}[uprev .+ a121*k1*dt .+ b121*g1[:,k]*integrator.sqdt for k=1:m]
  end

  # # H_i^(k), stage 3
  if typeof(W.dW) <: Number
    H13 = uprev + a131*k1*dt + b131*g1*integrator.sqdt
  elseif is_diagonal_noise(integrator.sol.prob)
    H13 = Vector{typeof(uprev)}[uprev .+ a131*k1*dt .+ b131*g1[k]*integrator.sqdt for k=1:m]
  else
    H13 = Vector{typeof(uprev)}[uprev .+ a131*k1*dt .+ b131*g1[:,k]*integrator.sqdt for k=1:m]
  end

  # H^_i^(k), stage 1
  # H21 = uprev
  # H^_i^(k), stage 2

  if typeof(W.dW) <: Number
    g2 = integrator.g(H12,p,t+c12*dt)
    g3 = integrator.g(H13,p,t+c13*dt)
    # for m=1:  H22 = uprev
  else
    g2 = [integrator.g(H12[k],p,t+c12*dt) for k=1:m]
    g3 = [integrator.g(H13[k],p,t+c13*dt) for k=1:m]
    H22 = [uprev for k=1:m]
    # add inbounds for speed if working properly
    for k=1:m
      for l=1:m
        if k == l
          continue
        end
        if is_diagonal_noise(integrator.sol.prob)
          @.. H22[k] += (b221*g1[l]+b222*g2[l][l]+b223*g3[l][l])*Ihat2[k,l]/integrator.sqdt
        else
          H22[k] += (b221*g1[:,l]+b222*g2[l][:,l]+b223*g3[l][:,l])*Ihat2[k,l]/integrator.sqdt
        end
      end
    end
  end

  # H^_i^(k), stage 3
  # for m=1: H23 = uprev
  if !(typeof(W.dW) <: Number)
    H23 = [uprev for k=1:m]
    # add inbounds for speed if working properly
    for k=1:m
      for l=1:m
        if k == l
          continue
        end
        if is_diagonal_noise(integrator.sol.prob)
          @.. H23[k] += (b231*g1[l]+b232*g2[l][l]+b233*g3[l][l])*Ihat2[k,l]/integrator.sqdt
        else
          H23[k] += (b231*g1[:,l]+b232*g2[l][:,l]+b233*g3[l][:,l])*Ihat2[k,l]/integrator.sqdt
        end
      end
    end
  end

  # add stages together Eq. (3)
  u = uprev + α1*k1*dt + α2*k2*dt + α3*k3*dt

  # add noise
  if typeof(W.dW) <: Number
    # lines 2 and 3
    u += g1*(_dW*beta11) + g2*(_dW*beta12+chi1*beta22/integrator.sqdt) + g3*(_dW*beta13+chi1*beta23/integrator.sqdt)
    # lines 4 and 5 are zero by construction
    # u += g1*(_dW*(beta31+beta32+beta33)+chi1*integrator.sqdt*(beta42+beta43))
  else
      if is_diagonal_noise(integrator.sol.prob)
        u += g1.*_dW*beta11
        for k=1:m
          u[k] += g2[k][k]*_dW[k]*beta12+g3[k][k]*_dW[k]*beta13
          u[k] += g2[k][k]*chi1[k]*beta22/integrator.sqdt + g3[k][k]*chi1[k]*beta23/integrator.sqdt
          tmpg = integrator.g(H22[k],p,t)
          u[k] = u[k] + g1[k]*_dW[k]*beta31 + tmpg[k]*(_dW[k]*beta32 + integrator.sqdt*beta42)
          tmpg = integrator.g(H23[k],p,t)
          u[k] = u[k] + tmpg[k]*(_dW[k]*beta33 + integrator.sqdt*beta43)
        end
      else
        # non-diag noise
        for k=1:m
          g1k = @view g1[:,k]
          g2k = @view g2[k][:,k]
          g3k = @view g3[k][:,k]
          @.. u = u + g1k*_dW[k]*(beta11+beta31)
          @.. u = u + g2k*_dW[k]*beta12 + g3k*_dW[k]*beta13
          @.. u = u + g2k*chi1[k]*beta22/integrator.sqdt + g3k*chi1[k]*beta23/integrator.sqdt
          tmpg = integrator.g(H22[k],p,t)
          @.. u = u + tmpgk*_dW[k]*beta32 + tmpgk*integrator.sqdt*beta42
          tmpg = integrator.g(H23[k],p,t)
          @.. u = u + tmpgk*_dW[k]*beta33 + tmpgk*integrator.sqdt*beta43
        end
      end
  end

  # Test EM scheme:
  # integrator.u = uprev + 1*k1*dt + 1*g1*_dW

  integrator.u = u

end



@muladd function perform_step!(integrator,cache::DRI1Cache,f=integrator.f)
  @unpack t,dt,uprev,u,W,p = integrator
  @unpack _dW,_dZ,chi1,Ihat2,tab,g1,g2,g3,k1,k2,k3,H02,H03,H12,H13,H22,H23,tmp1,tmpg = cache
  @unpack a021,a031,a032,a121,a131,b021,b031,b121,b131,b221,b222,b223,b231,b232,b233,α1,α2,α3,c02,c03,c12,c13,beta11,beta12,beta13,beta22,beta23,beta31,beta32,beta33,beta42,beta43,NORMAL_ONESIX_QUANTILE = cache.tab

  m = length(W.dW)

  if typeof(W.dW) <: Union{SArray,Number}
    # tbd
    _dW = map(x -> calc_threepoint_random(integrator, NORMAL_ONESIX_QUANTILE, x), W.dW / sqrt(dt))
  else
    # define three-point distributed random variables
    @.. chi1 = W.dW / sqrt(dt)
    calc_threepoint_random!(_dW, integrator, NORMAL_ONESIX_QUANTILE, chi1)
    map!(x -> (x^2-dt)/2, chi1, _dW)

    # define two-point distributed random variables
    calc_twopoint_random!(_dZ,integrator,W.dZ)

    for k = 1:m
      for l = 1:m
        if k<l
          Ihat2[k, l] = (_dW[k]*_dW[l]-integrator.sqdt*_dZ[k])/2
        elseif l<k
          Ihat2[k, l] = (_dW[k]*_dW[l]+integrator.sqdt*_dZ[l])/2
        else k==l
          Ihat2[k, k] = chi1[k]
        end
      end
    end
  end

  # compute stage values
  integrator.f(k1,uprev,p,t)
  integrator.g(g1,uprev,p,t)

  # H_i^(0), stage 1
  # H01 = uprev
  # H_i^(0), stage 2
  if is_diagonal_noise(integrator.sol.prob)
    @.. H02 = uprev + a021*k1*dt + b021*g1*_dW
  else
    mul!(tmp1,g1,_dW)
    @.. H02 = uprev + dt*a021*k1 + b021*tmp1
  end

  integrator.f(k2,H02,p,t+c02*dt)
  if is_diagonal_noise(integrator.sol.prob)
    @.. H03 = uprev + a032*k2*dt + a031*k1*dt + b031*g1*_dW
  else
    @.. H03 = uprev + a032*k2*dt + a031*k1*dt + b031*tmp1
  end

  integrator.f(k3,H03,p,t+c03*dt)

  # H_i^(k), stages
  # H11 = uprev
  for k=1:m
    if is_diagonal_noise(integrator.sol.prob)
      @.. H12[k] = uprev + a121*k1*dt + b121*g1[k]*integrator.sqdt
      @.. H13[k] = uprev + a131*k1*dt + b131*g1[k]*integrator.sqdt
    else
      g1k = @view g1[:,k]
      @.. H12[k] = uprev + a121*k1*dt + b121*g1k*integrator.sqdt
      @.. H13[k] = uprev + a131*k1*dt + b131*g1k*integrator.sqdt
    end
  end
  # H^_i^(k), stages

  for k=1:m
    integrator.g(g2[k],H12[k],p,t+c12*dt)
    integrator.g(g3[k],H13[k],p,t+c13*dt)

    H22[k] = uprev
    H23[k] = uprev
  end

  for k=1:m
    for l=1:m
      if k == l
        continue
      end
      if is_diagonal_noise(integrator.sol.prob)
        @.. H22[k] = H22[k]+(b221*g1[l]+b222*g2[l][l]+b223*g3[l][l])*Ihat2[k,l]/integrator.sqdt
        @.. H23[k] = H23[k]+(b231*g1[l]+b232*g2[l][l]+b233*g3[l][l])*Ihat2[k,l]/integrator.sqdt
      else
        g1l = @view g1[:,l]
        g2l = @view g2[l][:,l]
        g3l = @view g3[l][:,l]
        @.. H22[k] = H22[k]+(b221*g1l+b222*g2l+b223*g3l)*Ihat2[k,l]/integrator.sqdt
        @.. H23[k] = H23[k]+(b231*g1l+b232*g2l+b233*g3l)*Ihat2[k,l]/integrator.sqdt
      end
    end
  end

  # add stages together Eq. (3)
  @.. u = uprev + α1*k1*dt + α2*k2*dt + α3*k3*dt

  # add noise
  if is_diagonal_noise(integrator.sol.prob)
      @.. u = u + g1*_dW*beta11
      for k=1:m
        u[k] = u[k] + g2[k][k]*_dW[k]*beta12 + g3[k][k]*_dW[k]*beta13
        u[k] = u[k]  + g2[k][k]*chi1[k]*beta22/integrator.sqdt + g3[k][k]*chi1[k]*beta23/integrator.sqdt
        if m > 1
          integrator.g(tmpg,H22[k],p,t)
          u[k] = u[k] + g1[k]*_dW[k]*beta31 + tmpg[k]*(_dW[k]*beta32 + integrator.sqdt*beta42)
          integrator.g(tmpg,H23[k],p,t)
          u[k] = u[k] + tmpg[k]*(_dW[k]*beta33 + integrator.sqdt*beta43)
        end
      end
  else
    for k=1:m
      g1k = @view g1[:,k]
      g2k = @view g2[k][:,k]
      g3k = @view g3[k][:,k]
      tmpgk = @view tmpg[:,k]
      @.. u = u + g1k*_dW[k]*(beta11+beta31)
      @.. u = u + g2k*_dW[k]*beta12 + g3k*_dW[k]*beta13
      @.. u = u + g2k*chi1[k]*beta22/integrator.sqdt + g3k*chi1[k]*beta23/integrator.sqdt
      integrator.g(tmpg,H22[k],p,t)
      @.. u = u + tmpgk*_dW[k]*beta32 + tmpgk*integrator.sqdt*beta42
      integrator.g(tmpg,H23[k],p,t)
      @.. u = u + tmpgk*_dW[k]*beta33 + tmpgk*integrator.sqdt*beta43
    end
  end

end



# Roessler SRK for first order weak approx
@muladd function perform_step!(integrator,cache::RDI1WMConstantCache,f=integrator.f)
  @unpack a021,b021,α1,α2,c02,beta11,NORMAL_ONESIX_QUANTILE = cache
  @unpack t,dt,uprev,u,W,p = integrator

  # define three-point distributed random variables
  dW_scaled = W.dW / sqrt(dt)
  _dW = map(x -> calc_threepoint_random(integrator, NORMAL_ONESIX_QUANTILE, x), dW_scaled)
  chi1 = map(x -> (x^2-dt)/2, _dW) # diagonal of Ihat2
  if !(typeof(W.dW) <: Number)
    m = length(W.dW)
    # define two-point distributed random variables
    _dZ = map(x -> calc_twopoint_random(integrator, x),  W.dZ)
    Ihat2 = zeros(eltype(W.dZ), m, m) # I^_(k,l)
    for k = 1:m
      for l = 1:m
        if k<l
          Ihat2[k, l] = (_dW[k]*_dW[l]-integrator.sqdt*_dZ[k])/2
        elseif l<k
          Ihat2[k, l] = (_dW[k]*_dW[l]+integrator.sqdt*_dZ[l])/2
        else k==l
          Ihat2[k, k] = chi1[k]
        end
      end
    end
  end

  # compute stage values
  k1 = integrator.f(uprev,p,t)
  g1 = integrator.g(uprev,p,t)

  # H_i^(0), stage 1
  # H01 = uprev
  # H_i^(0), stage 2
  if !is_diagonal_noise(integrator.sol.prob) || typeof(W.dW) <: Number
    H02 = uprev + a021*k1*dt + b021*g1*_dW
  else
    H02 = uprev + a021*k1*dt + b021*g1.*_dW
  end
  k2 = integrator.f(H02,p,t+c02*dt)

  # add stages together Eq. (3)
  u = uprev + α1*k1*dt + α2*k2*dt

  # add noise
  if typeof(W.dW) <: Number
    # lines 2 and 3
    u += g1*(_dW*beta11)
  else
      if is_diagonal_noise(integrator.sol.prob)
        u += g1.*_dW*beta11
      else
        # non-diag noise
        for k=1:m
          g1k = @view g1[:,k]
          @.. u = u + g1k*_dW[k]*(beta11)
        end
      end
  end

  integrator.u = u

end



@muladd function perform_step!(integrator,cache::RDI1WMCache,f=integrator.f)
  @unpack t,dt,uprev,u,W,p = integrator
  @unpack _dW,_dZ,chi1,Ihat2,tab,g1,k1,k2,H02,tmp1 = cache
  @unpack a021,b021,α1,α2,c02,beta11,NORMAL_ONESIX_QUANTILE = cache.tab

  m = length(W.dW)

  if typeof(W.dW) <: Union{SArray,Number}
    # tbd
    _dW = map(x -> calc_threepoint_random(integrator, NORMAL_ONESIX_QUANTILE, x), W.dW / sqrt(dt))
  else
    # define three-point distributed random variables
    @.. chi1 = W.dW / sqrt(dt)
    calc_threepoint_random!(_dW, integrator, NORMAL_ONESIX_QUANTILE, chi1)
    map!(x -> (x^2-dt)/2, chi1, _dW)

    # define two-point distributed random variables
    calc_twopoint_random!(_dZ,integrator,W.dZ)

    for k = 1:m
      for l = 1:m
        if k<l
          Ihat2[k, l] = (_dW[k]*_dW[l]-integrator.sqdt*_dZ[k])/2
        elseif l<k
          Ihat2[k, l] = (_dW[k]*_dW[l]+integrator.sqdt*_dZ[l])/2
        else k==l
          Ihat2[k, k] = chi1[k]
        end
      end
    end
  end

  # compute stage values
  integrator.f(k1,uprev,p,t)
  integrator.g(g1,uprev,p,t)

  # H_i^(0), stage 1
  # H01 = uprev
  # H_i^(0), stage 2
  if is_diagonal_noise(integrator.sol.prob)
    @.. H02 = uprev + a021*k1*dt + b021*g1*_dW
  else
    mul!(tmp1,g1,_dW)
    @.. H02 = uprev + dt*a021*k1 + b021*tmp1
  end

  integrator.f(k2,H02,p,t+c02*dt)

  # add stages together Eq. (3)
  @.. u = uprev + α1*k1*dt + α2*k2*dt

  # add noise
  if is_diagonal_noise(integrator.sol.prob)
      @.. u = u + g1*_dW*beta11
  else
    for k=1:m
      g1k = @view g1[:,k]
      @.. u = u + g1k*_dW[k]*beta11
    end
  end
end



# Stratonovich sense

@muladd function perform_step!(integrator,cache::RSConstantCache,f=integrator.f)
  @unpack a021,a031,a032,a131,a141,b031,b032,b121,b131,b132,b141,b142,b143,b221,b231,b331,b332,b341,b342,α1,α2,α3,α4,c02,c03,c13,c14,beta11,beta12,beta13,beta14,beta22,beta23,NORMAL_ONESIX_QUANTILE = cache
  @unpack t,dt,uprev,u,W,p = integrator

  # define three-point distributed random variables
  dW_scaled = W.dW / sqrt(dt)
  _dW = map(x -> calc_threepoint_random(integrator, NORMAL_ONESIX_QUANTILE, x), dW_scaled)
  if !(typeof(W.dW) <: Number)
    m = length(W.dW)
    # define two-point distributed random variables
    _dZ = map(x -> calc_twopoint_random(integrator, x),  W.dZ)
    Ihat2 = zeros(eltype(W.dZ), m, m) # I^_(k,l)
    for k = 1:m
      for l = 1:k-1
        Ihat2[k, l] = _dW[k]*_dZ[l]
        Ihat2[l, k] = -_dW[k]*_dZ[l]
      end
    end
  end
  # compute stage values
  k1 = integrator.f(uprev,p,t)
  g1 = integrator.g(uprev,p,t)

  # H_1^(0)
  # H01 = uprev
  # H_2^(0)
  H02 = uprev + a021*k1*dt

  # H_1^(k)
  # H11 = uprev
  # H_2^(k), stage 2
  if typeof(W.dW) <: Number
    H12 = uprev + b121*g1*_dW
  elseif is_diagonal_noise(integrator.sol.prob)
    H12 = Vector{typeof(uprev)}[uprev .+ b121*g1[k]*_dW[k] for k=1:m]
  else
    H12 = Vector{typeof(uprev)}[uprev .+ b121*g1[:,k]*_dW[k] for k=1:m]
  end

  if typeof(W.dW) <: Number
    g2 = integrator.g(H12,p,t)
  else
    g2 = [integrator.g(H12[k],p,t) for k=1:m]
  end

  # H_3^(k)
  if typeof(W.dW) <: Number
    H13 = uprev + a131*k1*dt + b131*g1*_dW + b132*g2*_dW
  else
    H13 = [zero(typeof(uprev)) for k=1:m]
    for k=1:m
      H13[k] += uprev .+ a131*k1*dt
      if is_diagonal_noise(integrator.sol.prob)
        H13[k] += b131*g1[k]*_dW[k] .+ b132*g2[k]*_dW[k]
        for l=1:m
          if l!=k
            H13[k] += b331*g1[l]*_dW[l] .+ b332*g2[l][l]*_dW[l]
          end
        end
      else
        H13 += b131*g1[:,k]*_dW[k] .+ b132*g2[k][:,k]*_dW[k]
        for l=1:m
          if l!=k
            H13[k] += b331*g1[:,l]*_dW[l] .+ b332*g2[l][:,l]*_dW[l]
          end
        end
      end
    end
  end

  if typeof(W.dW) <: Number
    g3 = integrator.g(H13,p,t+c13*dt)
  else
    g3 = [integrator.g(H13[k],p,t+c13*dt) for k=1:m]
  end
  # H_3^(k)
  if typeof(W.dW) <: Number
    H14 = uprev + a141*k1*dt + b141*g1*_dW + b142*g2*_dW + b143*g3*_dW
  else
    H14 = [zero(typeof(uprev)) for k=1:m]
    for k=1:m
      H14[k] += uprev .+ a141*k1*dt
      if is_diagonal_noise(integrator.sol.prob)
        H14[k] += b141*g1[k]*_dW[k] .+ b142*g2[k]*_dW[k] .+ b143*g3[k]*_dW[k]
        for l=1:m
          if l!=k
            H14[k] += b341*g1[l]*_dW[l] .+ b342*g2[l][l]*_dW[l]
          end
        end
      else
        H14 += b141*g1[:,k]*_dW[k] .+ b142*g2[k][:,k]*_dW[k] .+ b143*g3[k][:,k]*_dW[k]
        for l=1:m
          if l!=k
            H14[k] += b341*g1[:,l]*_dW[l] .+ b342*g2[l][:,l]*_dW[l]
          end
        end
      end
    end
  end

  if typeof(W.dW) <: Number
    g4 = integrator.g(H14,p,t+c14*dt)
  else
    g4 = [integrator.g(H14[k],p,t+c14*dt) for k=1:m]
  end

  # H_3^(0) (requires H_2^(k))
  k2 = integrator.f(H02,p,t+c02*dt)
  H03 = uprev + a032*k2*dt + a031*k1*dt

  if !is_diagonal_noise(integrator.sol.prob) || typeof(W.dW) <: Number
    H03 += b031*g1*_dW
    if typeof(W.dW) <: Number
      H03 += b032*g2*_dW
    else
      for k=1:m
        H03 += b032*g2[k][:,k]*_dW[k]
      end
    end
  else
    H03 += b031*g1.*_dW
    for k=1:m
      H03 += b032*g2[k][k]*_dW[k]
    end
  end

  k3 = integrator.f(H03,p,t+c03*dt)

  # H_4^(0)
  # H04 = uprev; k4 = integrator.f(uprev,p,t+0*dt) = k1


  # H^_1^(k)
  # H21 = uprev
  # H^_2^(k) # H^_3^(k)

  if !(typeof(W.dW) <: Number)
    H22 = [uprev for k=1:m]
    H23 = [uprev for k=1:m]
    # add inbounds for speed if working properly
    for k=1:m
      for l=1:m
        if k == l
          continue
        end
        if is_diagonal_noise(integrator.sol.prob)
          @.. H22[k] += b221*g1[l]*Ihat2[k,l]/integrator.sqdt
          @.. H23[k] += b231*g1[l]*Ihat2[k,l]/integrator.sqdt
        else
          H22[k] += b221*g1[:,l]*Ihat2[k,l]/integrator.sqdt
          H23[k] += b231*g1[:,l]*Ihat2[k,l]/integrator.sqdt
        end
      end
    end
  end
  # H^_4^(k)
  # H24 = uprev

  # add stages together Eq. (5.1)
  u = uprev + (α1*k1 + α2*k2 + α3*k3 + α4*k1)*dt

  # add noise
  if typeof(W.dW) <: Number
    u += (g1*beta11+g2*beta12+g3*beta13+g4*beta14)*_dW # beta2 terms are zero by construction
  else
      if is_diagonal_noise(integrator.sol.prob)
        u += g1.*_dW*beta11
        for k=1:m
          u[k] += (g2[k][k]*beta12+g3[k][k]*beta13+g4[k][k]*beta14)*_dW[k]
          tmpg = integrator.g(H22[k],p,t)
          u[k] = u[k] + tmpg[k]*beta22*integrator.sqdt
          tmpg = integrator.g(H23[k],p,t)
          u[k] = u[k] + tmpg[k]*beta23*integrator.sqdt
        end
      else
        # non-diag noise
        for k=1:m
          g1k = @view g1[:,k]
          g2k = @view g2[k][:,k]
          g3k = @view g3[k][:,k]
          g4k = @view g4[k][:,k]
          @.. u = u + (g1k*beta11 + g2k*beta12 + g3k*beta13 + g4k*beta14)*_dW[k]
          tmpg = integrator.g(H22[k],p,t)
          @.. u = u + tmpg*beta22*integrator.sqdt
          tmpg = integrator.g(H23[k],p,t)
          @.. u = u + tmpg*beta23*integrator.sqdt
        end
      end
  end

  integrator.u = u
end


@muladd function perform_step!(integrator,cache::RSCache,f=integrator.f)
  @unpack t,dt,uprev,u,W,p = integrator
  @unpack _dW,_dZ,chi1,Ihat2,tab,g1,g2,g3,g4,k1,k2,k3,H02,H03,H12,H13,H14,H22,H23,tmp1,tmpg = cache
  @unpack a021,a031,a032,a131,a141,b031,b032,b121,b131,b132,b141,b142,b143,b221,b231,b331,b332,b341,b342,α1,α2,α3,α4,c02,c03,c13,c14,beta11,beta12,beta13,beta14,beta22,beta23,NORMAL_ONESIX_QUANTILE = cache.tab

  m = length(W.dW)

  if typeof(W.dW) <: Union{SArray,Number}
    # tbd
    _dW = map(x -> calc_threepoint_random(integrator, NORMAL_ONESIX_QUANTILE, x), W.dW / sqrt(dt))
  else
    # define three-point distributed random variables
    @.. chi1 = W.dW / sqrt(dt)
    calc_threepoint_random!(_dW, integrator, NORMAL_ONESIX_QUANTILE, chi1)
    map!(x -> (x^2-dt)/2, chi1, _dW)

    # define two-point distributed random variables
    calc_twopoint_random!(_dZ,integrator,W.dZ)

    for k = 1:m
      for l = 1:k-1
        Ihat2[k, l] = _dW[k]*_dZ[l]
        Ihat2[l, k] = -_dW[k]*_dZ[l]
      end
    end
  end

  # compute stage values
  integrator.f(k1,uprev,p,t)
  integrator.g(g1,uprev,p,t)

  # H_1^(0)
  # H01 = uprev
  # H_2^(0)
  @.. H02 = uprev + a021*k1*dt

  # H_1^(k)
  # H11 = uprev
  # H_2^(k), stage 2

  if is_diagonal_noise(integrator.sol.prob)
    for k=1:m
      @.. H12[k] = uprev + b121*g1[k]*_dW[k]
    end
  else
    for k=1:m
      g1k = @view g1[:,k]
      @.. H12[k] = uprev .+ b121*g1k*_dW[k]
    end
  end


  for k=1:m
    integrator.g(g2[k],H12[k],p,t)
  end

  # H_3^(k)
  for k=1:m
    @.. H13[k] = uprev+a131*k1*dt
    if is_diagonal_noise(integrator.sol.prob)
      @.. H13[k] = H13[k] + b131*g1[k]*_dW[k] + b132*g2[k]*_dW[k]
      for l=1:m
        if l!=k
          @.. H13[k] = H13[k] + b331*g1[l]*_dW[l] + b332*g2[l]*_dW[l]
        end
      end
    else
      g1k = @view g1[:,k]
      g2k = @view g2[k][:,k]
      @.. H13[k] = H13[k] + b131*g1k*_dW[k] + b132*g2k*_dW[k]
      for l=1:m
        if l!=k
          g1l = @view g1[:,l]
          g2l = @view g2[l][:,l]
          @.. H13[k] = H13[k] + b331*g1l*_dW[l] + b332*g2l*_dW[l]
        end
      end
    end
  end


  for k=1:m
    integrator.g(g3[k],H13[k],p,t+c13*dt)
  end

  # H_3^(k)
  for k=1:m
    @.. H14[k] = uprev + a141*k1*dt
    if is_diagonal_noise(integrator.sol.prob)
      @.. H14[k] = H14[k] + b141*g1[k]*_dW[k] + b142*g2[k]*_dW[k] + b143*g3[k]*_dW[k]
      for l=1:m
        if l!=k
          @.. H14[k] = H14[k] + b341*g1[l]*_dW[l] .+ b342*g2[l]*_dW[l]
        end
      end
    else
      g1k = @view g1[:,k]
      g2k = @view g2[k][:,k]
      g3k = @view g3[k][:,k]

      @.. H14[k] = H14[k] + b141*g1k*_dW[k] + b142*g2k*_dW[k] + b143*g3k*_dW[k]
      for l=1:m
        if l!=k
          g1l = @view g1[:,l]
          g2l = @view g2[l][:,l]
          @.. H14[k] = H14[k] + b341*g1l*_dW[l] + b342*g2l*_dW[l]
        end
      end
    end
  end

  for k=1:m
    integrator.g(g4[k],H14[k],p,t+c14*dt)
  end

  # H_3^(0) (requires H_2^(k))
  integrator.f(k2,H02,p,t+c02*dt)
  @.. H03 = uprev + a032*k2*dt + a031*k1*dt

  if !is_diagonal_noise(integrator.sol.prob) || typeof(W.dW) <: Number
    mul!(tmp1,g1,_dW)
    @.. H03 = H03 + b031*tmp1
    for k=1:m
      g2k = @view g2[k][:,k]
      @.. H03 = H03 +  b032*g2k*_dW[k]
    end
  else
    @.. H03 = H03 + b031*g1*_dW
    for k=1:m
      @.. H03 = H03 + b032*g2[k][k]*_dW[k]
    end
  end

  integrator.f(k3,H03,p,t+c03*dt)

  # H_4^(0)
  # H04 = uprev; k4 = integrator.f(uprev,p,t+0*dt) = k1


  # H^_1^(k)
  # H21 = uprev
  # H^_2^(k) # H^_3^(k)

  if (!(typeof(W.dW) <: Number) || (m!=1))
    for k=1:m
     H22[k] = uprev
     H23[k] = uprev
    end
    for k=1:m
      for l=1:m
        if k == l
          continue
        end
        if is_diagonal_noise(integrator.sol.prob)
          @.. H22[k] = H22[k] + b221*g1[l]*Ihat2[k,l]/integrator.sqdt
          @.. H23[k] = H23[k] + b231*g1[l]*Ihat2[k,l]/integrator.sqdt
        else
          g1l = @view g1[:,l]
          @.. H22[k] = H22[k] + b221*g1l*Ihat2[k,l]/integrator.sqdt
          @.. H23[k] = H23[k] + b231*g1l*Ihat2[k,l]/integrator.sqdt
        end
      end
    end
  end
  # H^_4^(k)
  # H24 = uprev

  # add stages together Eq. (5.1)
  @.. u = uprev + (α1*k1 + α2*k2 + α3*k3 + α4*k1)*dt

  # add noise

  if is_diagonal_noise(integrator.sol.prob)
    @.. u = u + g1*_dW*beta11
    for k=1:m
      u[k] = u[k] + (g2[k][k]*beta12+g3[k][k]*beta13+g4[k][k]*beta14)*_dW[k]
      if m != 1
        integrator.g(tmpg,H22[k],p,t)
        u[k] = u[k] + tmpg[k]*beta22*integrator.sqdt
        integrator.g(tmpg,H23[k],p,t)
        u[k] = u[k] + tmpg[k]*beta23*integrator.sqdt
      end
    end
  else
    # non-diag noise
    for k=1:m
      g1k = @view g1[:,k]
      g2k = @view g2[k][:,k]
      g3k = @view g3[k][:,k]
      g4k = @view g4[k][:,k]
      tmpgk = @view tmpg[:,k]
      @.. u = u + (g1k*beta11 + g2k*beta12 + g3k*beta13 + g4k*beta14)*_dW[k]
      integrator.g(tmpg,H22[k],p,t)
      @.. u = u + tmpgk*beta22*integrator.sqdt
      integrator.g(tmpg,H23[k],p,t)
      @.. u = u + tmpgk*beta23*integrator.sqdt
    end
  end
end


# PL1WM
@muladd function perform_step!(integrator,cache::PL1WMConstantCache,f=integrator.f)
  @unpack NORMAL_ONESIX_QUANTILE = cache
  @unpack t,dt,uprev,u,W,p = integrator

  m = length(W.dW)
  # define three-point distributed random variables
  dW_scaled = W.dW / integrator.sqdt
  _dW = map(x -> calc_threepoint_random(integrator, NORMAL_ONESIX_QUANTILE, x), dW_scaled)
  chi1 = map(x -> (x^2-dt)/4, _dW)
  if !(typeof(W.dW) <: Number)
    # define two-point distributed random variables
    _dZ = map(x -> calc_twopoint_random(integrator, x),  W.dZ)
    Ihat2 = zeros(eltype(W.dZ), m, m) # I^_(k,l)
    for k = 1:m
      Ihat2[k, k] = -dt
      for l = 1:k-1
        Ihat2[k, l] = _dZ[Int(1+1//2*(k-3)*k+l)]
      	Ihat2[l, k] = -Ihat2[k, l]
      end
    end
  end
  # compute stage values
  k1 = integrator.f(uprev,p,t)
  g1 = integrator.g(uprev,p,t)

  # Y, Yp, Ym
  if !is_diagonal_noise(integrator.sol.prob) || typeof(W.dW) <: Number
    Y = uprev + k1*dt + g1*_dW
    if typeof(W.dW) <: Number
      Yp = uprev + k1*dt + g1*integrator.sqdt
      Ym = uprev + k1*dt - g1*integrator.sqdt
    else
      Yp = Vector{typeof(uprev)}[uprev .+ k1*dt .+ g1[:,k]*integrator.sqdt for k=1:m]
      Ym = Vector{typeof(uprev)}[uprev .+ k1*dt .- g1[:,k]*integrator.sqdt for k=1:m]
    end
  else
    Y = uprev + k1*dt + g1.*_dW
    Yp = Vector{typeof(uprev)}(undef,m)
    Ym = Vector{typeof(uprev)}(undef,m)
    for k=1:m
      Yp[k] = uprev .+ k1*dt .+ g1[k]*integrator.sqdt
      Ym[k] = uprev .+ k1*dt .- g1[k]*integrator.sqdt
    end
  end

  k2 = integrator.f(Y,p,t)

  # add stages together (Ch 15.1 Eq.(1.3))
  u = uprev + 1//2*(k1+k2)*dt

  # add noise
  if typeof(W.dW) <: Number
    g2p = integrator.g(Yp,p,t)
    g2m = integrator.g(Ym,p,t)
    u += 1//4*(g2p+g2m+2*g1)*_dW + (g2p-g2m)*chi1/integrator.sqdt #(1.1)
  else
    if is_diagonal_noise(integrator.sol.prob)
      for k=1:m
        tmpg1 = integrator.g(Yp[k],p,t)
        tmpg2 = integrator.g(Ym[k],p,t)
        @.. u += 1//4*(tmpg1[k]+tmpg2[k]+2*g1[k])*_dW[k]
        @.. u += (tmpg1[k]-tmpg2[k])*chi1[k]/integrator.sqdt
        for l=1:m
          if l!=k
            Ulp = @.. uprev + g1[l]*integrator.sqdt
            Ulm = @.. uprev - g1[l]*integrator.sqdt

            tmpg1 = integrator.g(Ulp,p,t)
            tmpg2 = integrator.g(Ulm,p,t)
            @.. u += 1//4*(tmpg1[k]+tmpg2[k]-2*g1[k])*_dW[k]
            @.. u += 1//4*(tmpg1[k]-tmpg2[k])*(_dW[k]*_dW[l] + Ihat2[l,k])/integrator.sqdt
          end
        end
      end
      else
        # non-diag noise
        for k=1:m
          tmpg1 = integrator.g(Yp[k],p,t)
          tmpg2 = integrator.g(Ym[k],p,t)

          u += 1//4*(tmpg1[:,k]+tmpg2[:,k]+2*g1[:,k])*_dW[k]
          u += (tmpg1[:,k]-tmpg2[:,k])*chi1[k]/integrator.sqdt
          for l=1:m
            if l!=k
              Ulp = uprev + g1[:,l]*integrator.sqdt
              Ulm = uprev - g1[:,l]*integrator.sqdt

              tmpg1 = integrator.g(Ulp,p,t)
              tmpg2 = integrator.g(Ulm,p,t)
              u += 1//4*(tmpg1[:,k]+tmpg2[:,k]-2*g1[:,k])*_dW[k]
              u += 1//4*(tmpg1[:,k]-tmpg2[:,k])*(_dW[k]*_dW[l] + Ihat2[l,k])/integrator.sqdt
            end
          end
        end
      end
  end
  integrator.u = u
end


@muladd function perform_step!(integrator,cache::PL1WMCache,f=integrator.f)
  @unpack t,dt,uprev,u,W,p = integrator
  @unpack _dW,_dZ,chi1,Ihat2,tab,g1,k1,k2,Y,Yp,Ym,tmp1,tmpg1,tmpg2,Ulp,Ulm = cache
  @unpack NORMAL_ONESIX_QUANTILE = cache.tab

  m = length(W.dW)
  # define three-point distributed random variables
  @.. chi1 = W.dW / integrator.sqdt
  calc_threepoint_random!(_dW, integrator, NORMAL_ONESIX_QUANTILE, chi1)
  map!(x -> (x^2-dt)/4, chi1, _dW)
  if !(typeof(W.dW) <: Number) || m > 1
    # define two-point distributed random variables
    calc_twopoint_random!(_dZ,integrator,W.dZ)
    for k = 1:m
      Ihat2[k, k] = -dt
      for l = 1:k-1
        Ihat2[k, l] = _dZ[Int(1+1//2*(k-3)*k+l)]
      	Ihat2[l, k] = -Ihat2[k, l]
      end
    end
  end
  # compute stage values
  integrator.f(k1,uprev,p,t)
  integrator.g(g1,uprev,p,t)

  # Y, Yp, Ym
  if !is_diagonal_noise(integrator.sol.prob) || typeof(W.dW) <: Number
    mul!(tmp1,g1,_dW)
    @.. Y = uprev + k1*dt + tmp1
    if typeof(W.dW) <: Number
      @.. Yp = uprev + k1*dt + g1*integrator.sqdt
      @.. Ym = uprev + k1*dt - g1*integrator.sqdt
    else
      for k=1:m
        g1k = @view g1[:,k]
        @.. Yp[k] = uprev + k1*dt + g1k*integrator.sqdt
        @.. Ym[k] = uprev + k1*dt - g1k*integrator.sqdt
      end
    end
  else
    @.. Y = uprev + k1*dt + g1*_dW
    for k=1:m
      @.. Yp[k] = uprev + k1*dt + g1[k]*integrator.sqdt
      @.. Ym[k] = uprev + k1*dt - g1[k]*integrator.sqdt
    end
  end

  integrator.f(k2,Y,p,t)

  # add stages together (Ch 15.1 Eq.(1.3))
  @.. u = uprev + 1//2*(k1+k2)*dt

  # add noise
  if typeof(W.dW) <: Number
    integrator.g(tmpg1,Yp,p,t)
    integrator.g(tmpg2,Ym,p,t)
    @.. u = u + 1//4*(tmpg1+tmpg2+2*g1)*_dW + 1//4*(tmpg1-tmpg2)*chi1[k]/integrator.sqdt #(1.1)
  else
    if !is_diagonal_noise(integrator.sol.prob) || typeof(W.dW) <: Number
      # non-diag noise
      for k=1:m
        integrator.g(tmpg1,Yp[k],p,t)
        integrator.g(tmpg2,Ym[k],p,t)
        tmpg1k = @view tmpg1[:,k]
        tmpg2k = @view tmpg2[:,k]
        g1k = @view g1[:,k]
        @.. u = u + 1//4*(tmpg1k+tmpg2k+2*g1k)*_dW[k]
        @.. u = u + (tmpg1k-tmpg2k)*chi1[k]/integrator.sqdt
        for l=1:m
          if l !=k
            g1l = @view g1[:,l]
            @.. Ulp = uprev + g1l*integrator.sqdt
            @.. Ulm = uprev - g1l*integrator.sqdt

            integrator.g(tmpg1,Ulp,p,t)
            integrator.g(tmpg2,Ulm,p,t)
            tmpg1k = @view tmpg1[:,k]
            tmpg2k = @view tmpg2[:,k]
            u += 1//4*(tmpg1k+tmpg2k-2*g1k)*_dW[k]
            u += 1//4*(tmpg1k-tmpg2k)*(_dW[k]*_dW[l] + Ihat2[l,k])/integrator.sqdt
          end
        end
      end
    else
      for k=1:m
        integrator.g(tmpg1,Yp[k],p,t)
        integrator.g(tmpg2,Ym[k],p,t)
        @.. u = u + 1//4*(tmpg1[k]+tmpg2[k]+2*g1[k])*_dW[k]
        @.. u = u + (tmpg1[k]-tmpg2[k])*chi1[k]/integrator.sqdt
        for l=1:m
          if l !=k
            @.. Ulp = uprev + g1[l]*integrator.sqdt
            @.. Ulm = uprev - g1[l]*integrator.sqdt

            integrator.g(tmpg1,Ulp,p,t)
            integrator.g(tmpg2,Ulm,p,t)
            @.. u = u + 1//4*(tmpg1[k]+tmpg2[k]-2*g1[k])*_dW[k]
            @.. u = u + 1//4*(tmpg1[k]-tmpg2[k])*(_dW[k]*_dW[l] + Ihat2[l,k])/integrator.sqdt
          end
        end
      end
    end
  end
end




# PL1WM
@muladd function perform_step!(integrator,cache::PL1WMAConstantCache,f=integrator.f)
  @unpack NORMAL_ONESIX_QUANTILE = cache
  @unpack t,dt,uprev,u,W,p = integrator

  # define three-point distributed random variables
  dW_scaled = W.dW / integrator.sqdt
  _dW = map(x -> calc_threepoint_random(integrator, NORMAL_ONESIX_QUANTILE, x), dW_scaled)

  # compute stage values
  k1 = integrator.f(uprev,p,t)
  g1 = integrator.g(uprev,p,t)

  # Y
  if !is_diagonal_noise(integrator.sol.prob) || typeof(W.dW) <: Number
    tmp1 = g1*_dW
  else
    tmp1 = g1.*_dW
  end
  Y = uprev + k1*dt + tmp1

  k2 = integrator.f(Y,p,t)

  # add stages together (Ch 15.1 Eq.(1.4))
  u = uprev + 1//2*(k1+k2)*dt + tmp1

  integrator.u = u
end



@muladd function perform_step!(integrator,cache::PL1WMACache,f=integrator.f)
  @unpack t,dt,uprev,u,W,p = integrator
  @unpack _dW,chi1,tab,g1,k1,k2,Y,tmp1 = cache
  @unpack NORMAL_ONESIX_QUANTILE = cache.tab


  # define three-point distributed random variables
  @.. chi1 = W.dW / integrator.sqdt
  calc_threepoint_random!(_dW, integrator, NORMAL_ONESIX_QUANTILE, chi1)

  # compute stage values
  integrator.f(k1,uprev,p,t)
  integrator.g(g1,uprev,p,t)

  # Y, Yp, Ym
  if !is_diagonal_noise(integrator.sol.prob) || typeof(W.dW) <: Number
    mul!(tmp1,g1,_dW)
    @.. Y = uprev + k1*dt + tmp1

  else
    @.. tmp1 = g1*_dW
    @.. Y = uprev + k1*dt + tmp1
  end

  integrator.f(k2,Y,p,t)

  # add stages together (Ch 15.1 Eq.(1.4))
  @.. u = uprev + 1//2*(k1+k2)*dt + tmp1

end
