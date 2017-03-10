#=========================================================================
# @@ physiological model
#=========================================================================

# For the cr and cw functions, see Minetti, http://jap.physiology.org/content/93/3/1039.full

def minetti(i)
  if $running then
    a,b,c,d,p = [26.073730183424228, 0.031038121935618928, 1.3809948743424785, -0.06547207947176657, 2.181405714691871]
  else
    a,b,c,d,p = [22.911633035337864, 0.02621471025436344, 1.3154310892336223, -0.08317260964525384, 2.208584834633906]
  end
  return (a*((i**p+b)**(1/p)+i/c+d)).abs
end
# Five-parameter fit to the following data:
#   c is minimized at imin, and has the correct value cmin there (see comments in i_to_iota())
#   slopes at +-infty are minetti's values: sp=9.8/0.218; sm=9.8/-1.062 for running, 
#                                           sp=9.8/0.243; sm=9.8/-1.215 for walking
#   match minetti's value at i=0.0
# original analytic work, with p=2 and slightly different values of sp and sm:
#    calc -e "x0=-0.181355; y0=1.781269; sp=9.8/.23; sm=9.8/-1.2; a=(sp-sm)/2; c=a/[(sp+sm)/2]; b=x0^2(c^2-1); d=(1/a)*{y0-a*[sqrt(x0^2+b)+x0/c]}; a(1-1/c)"
#    a = 25.3876811594203
#    c = 1.47422680412371
#    b = 0.0385908791280687
#    d = -0.0741786448190981
# I then optimized the parameters further, including p, numerically.

def minetti_original(i) # their 5th-order polynomial fits; these won't work well at extremes of i
  if $running then return minetti_cr(i) else return minetti_cw(i) end
end

def i_to_iota(i)
  # convert i to a linearized scale iota, where iota^2=[C(i)-C(imin)]/c2 and sign(iota)=sign(i-imin)
  # The following are the minima of the Minetti functions.
  if $running then
    imin = -0.181355
    cmin = 1.781269
    c2=66.0 # see comments at minetti_quadratic_coeffs()
  else
    imin = -0.152526
    cmin= 0.935493
    c2=94.0 # see comments at minetti_quadratic_coeffs()
  end
  c=minetti(i)
  if c<cmin then 
    # warning("c=#{c}, cmin=#{cmin}, i=#{i}, imin=#{imin}, running=#{$running}") 
    # happens sometimes due to rounding
    c=cmin
  end
  result = Math::sqrt((c-cmin)/c2)
  if i<imin then result= -result end
  return result
end

def minetti_quadratic_coeffs() # my rough approximation to Minetti, optimized to fit the range that's most common
  if $running then
    i0=-0.15
    c0=1.84
    c2=66.0
  else
    i0=-0.1
    c0=1.13
    c2=94.0
  end
  b0=c0+c2*i0*i0
  b1=-2*c2*i0
  b2=c2
  return [i0,c0,c2,b0,b1,b2]
end

def minetti_cr(i) # no longer used
  # i = gradient
  # cr = cost of running, in J/kg.m
  if i>0.5 || i<-0.5 then return minetti_steep(i) end
  return 155.4*i**5-30.4*i**4-43.3*i**3+46.3*i**2+19.5*i+3.6
  # note that the 3.6 is different from their best value of 3.4 on the flats, i.e., the polynomial isn't a perfect fit
end

def minetti_cw(i) # no longer used
  # i = gradient
  # cr = cost of walking, in J/kg.m
  if i>0.5 || i<-0.5 then return minetti_steep(i) end
  return 280.5*i**5-58.7*i**4-76.8*i**3+51.9*i**2+19.6*i+2.5
end

def minetti_steep(i) # no longer used
  g=9.8 # m/s2=J/kg.m
  if i>0 then eff=0.23 else eff=-1.2 end
  return g*i/eff
end
