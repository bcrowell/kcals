#!/usr/bin/ruby

# See README.md for documentation.

# to do: out and back option/detection

command_line_parameters=ARGV

def fatal_error(message)
  $stderr.print "whiz.rb: #{$verb} fatal error: #{message}\n"
  exit(-1)
end

$metric = false
$running = true # set to false for walking
$body_mass = 66 # in kg, =145 lb
$osc_h = 500 # typical wavelength, in meters, of bogus oscillations in height data
            # calculated gain is very sensitive to this
            # putting in this value, which I estimated by eye from a graph, seems to reproduce
            # mapmyrun's figure for total gain

def handle_param(s,where)
  if s=~/\A\s*(\w+)\s*=\s*([^\s]+)\Z/ then
    par,value = $1,$2
    recognized = false
    if par=='metric' then recognized=true; $metric=(value.to_i==1) end
    if par=='running' then recognized=true; $running=(value.to_i==1) end
    if par=='weight' then recognized=true; $body_mass=value.to_f end
    if par=='filtering' then recognized=true; $osc_h=value.to_f end
    if !recognized then fatal_error("illegal parameter #{par}#{where}:\n#{s}") end
  else
    fatal_error("illegal syntax#{where}:\n#{s}")
  end
end

# first read from prefs file:
prefs = "#{Dir.home}/.kcals"
begin
  open(prefs,'r') { |f|
    f.each_line {|line|
      next if line=~/\A\s*\Z/
      handle_param(line," in #{prefs}")
    }
  }
rescue
  print "Warning: File #{prefs} doesn't exist, so default values have been assumed for all parameters.\n"
end
# then override at command line:
command_line_parameters.each { |p| handle_param(p,'') }

print "units=#{$metric ? "metric" : "US"}, #{$running ? "running" : "walking"}, weight=#{$body_mass} kg, filtering=#{$osc_h} m\n"

# For the cr and cw functions, see Minetti, http://jap.physiology.org/content/93/3/1039.full

def minetti(i)
  if $running then return minetti_cr(i) else return minetti_cw(i) end
end

def minetti_cr(i)
  # i = gradient
  # cr = cost of running, in J/kg.m
  return 155.4*i**5-30.4*i**4-43.3*i**3+46.3*i**2+19.5*i+3.6
  # note that the 3.6 is different from their best value of 3.4 on the flats, i.e., the polynomial isn't a perfect fit
end

def minetti_cw(i)
  # i = gradient
  # cr = cost of walking, in J/kg.m
  return 280.5*i**5-58.7*i**4-76.8*i**3+51.9*i**2+19.6*i+2.5
end

def deg_to_rad(x)
  return 0.0174532925199433*x
end

def spherical_to_cartesian(lat,lon,alt,lat0,lon0)
  # inputs are in degrees, except for alt, which is in meters
  # The purpose of lat0 and lon0 is to do a rotation to make the cartesian coordinates easier to interpret.
  # outputs are in meters
  a = 6378137.0 # earth's equatorial radius, in meters
  b = 6356752.3 # polar radius
  lat_rad = deg_to_rad(lat)
  lon_rad = deg_to_rad(lon-lon0)
  slat = Math::sin(lat_rad)
  slon = Math::sin(lon_rad)
  clat = Math::cos(lat_rad)
  clon = Math::cos(lon_rad)
  slat0 = Math::sin(deg_to_rad(lat0))
  clat0 = Math::cos(deg_to_rad(lat0))
  r0 = Math::sqrt( ((a*a*clat0)**2+(b*b*slat0)**2) / ((a*clat0)**2+(b*slat0)**2))
        # https://en.wikipedia.org/wiki/Earth_radius#Geocentric_radius
        # Use initial latitude and keep r0 constant. If we let r0 vary, then we also need to figure
        # out the direction of the g vector in this model.
  r = r0+alt
  x = r*clat*clon
  y = r*clat*slon
  z = r*slat
  xx = x
  zz = z
  if true then
    xx =  clat0*x+slat0*z
    zz = -slat0*x+clat0*z
  end
  return [r,xx,y,zz]
end

cartesian = [] # array of [r,x,y,z]

first = true
lat0 = 0
lon0 = 0
$stdin.each_line { |line|
  if line=~/\AT\s+([^\s]+)\s+([^\s]+)\s+([^\s]+)/ then
    lat,lon,alt = $1.to_f,$2.to_f,$3.to_f # in degrees, degrees, meters
    if first then lat0=lat; lon0=lon end # for convenience of visualization and interp, subtract this off of all lons
    #print "#{lat},#{lon},#{alt}\n"
    # r,x,y,z = spherical_to_cartesian(lat,lon,alt)
    # print "#{x},#{y},#{z}\n"
    cartesian.push(spherical_to_cartesian(lat,lon,alt,lat0,lon0))
    first=false
  end
}

n = cartesian.length

#print "points read = #{n}\n"
if n==0 then $stderr.print "error, no points read successfully from input\n"; exit(-1) end

csv = ''

# definitions of variables:
#   h,v,d are cumulative horiz, vert, and slope distance
#   their increments are dh,dv,dd

hv = [] # array of [h,v]
first=true
x,y,z = 0,0,0
i=0
h=0
v=0
cartesian.each { |p|
  r,x2,y2,z2 = p
  if first then 
    first=false
  else
    dx,dy,dz=x2-x,y2-y,z2-z
    dl2 = dx*dx+dy*dy+dz*dz
    dv = (dx*x+dy*y+dz*z)/r # dot product of dr with rhat = vertical distance
    dh = Math::sqrt(dl2-dv*dv) # horizontal distance
    h = h+dh
    v = v+dv
  end
  hv.push([h,v]) # in first iteration, is [0,0]
  # if i<10 then print "#{"%9.2f" % [h]},#{"%9.2f" % [v]}\n" end
  x,y,z=x2,y2,z2
  i = i+1
}

# filtering to get rid of artifacts of bad digital elevation model, which have a big effect
# on calculations of gain

hv2 = []
hv.each { |a|
  h,v = a

  v_av = 0
  n_av = 0
  hv.each { |b|
    hh,vv = b
    if (hh-h).abs<$osc_h/2.0 then
      # print " yes\n"
      v_av = v_av+vv
      n_av = n_av+1
    end
  }
  if n_av<1 then fatal_error("n_av<1?? at h,v=#{h},#{v}") end
  v = v_av/n_av

  hv2.push([h,v])
}
hv = hv2

# integrate to find total gain, calories burned
h = 0 # total horizontal distance
v = 0 # total vertical distance (=0 at end of a loop)
d = 0 # total distance along the slope
gain = 0 # total gain
c = 0 # cost in joules
first = true
old_h = 0
old_v = 0
hv.each { |a|
  h,v = a
  if !first then
    dh = h-old_h
    dv = v-old_v
    dd = Math::sqrt(dh*dh+dv*dv)
    d = d+dd
    if dv>0 then gain=gain+dv end
    i=0
    if dh>0 then i=dv/dh end
    c = c+dd*$body_mass*minetti(i)
         # in theory it matters whether we use dd or dh here; I think from Minetti's math it's dd
    csv = csv + "#{"%9.2f" % [h]},#{"%9.2f" % [v]},#{"%7.2f" %  [dh]},#{"%7.2f" %  [dv]}\n"
  end
  old_h = h
  old_v = v
  first = false
}



if $metric then
  h_unit = "km"
  v_unit = "m"
  h = h/1000.0
  d = d/1000.0
else
  h_unit = "mi"
  v_unit = "ft"
  h = (h/1000.0)*0.621371
  d = (d/1000.0)*0.621371
  gain = gain*3.28084
end
kcals = c*0.000239006
print "horizontal distance = #{"%6.2f" % [h]} #{h_unit}\n"
print "slope distance = #{"%6.2f" % [d]} #{h_unit}\n"
print "gain = #{"%5.0f" % [gain]} #{v_unit}\n"
print "cost = #{"%5.0f" % [kcals]} kcals\n"

File.open('kcals.csv','w') { |f| 
  f.print csv
}
