#!/usr/bin/ruby

# reads stdin
# writes kcals.csv and total stats to output

# to do: out and back option/detection

$metric = false

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

print "points read = #{n}\n"
if n==0 then $stderr.print "error, no points read successfully from input\n"; exit(-1) end

csv = ''

# definitions of variables:
#   h,v,d are cumulative horiz, vert, and slope distance
#   their increments are dh,dv,dd

hv = [] # array of [h,dh,dv,dd]
first=true
x,y,z = 0,0,0
i=0
h=0
cartesian.each { |p|
  r,x2,y2,z2 = p
  if first then 
    first=false
  else
    dx,dy,dz=x2-x,y2-y,z2-z
    dl2 = dx*dx+dy*dy+dz*dz
    dv = (dx*x+dy*y+dz*z)/r # dot product of dr with rhat = vertical distance
    dh = Math::sqrt(dl2-dv*dv) # horizontal distance
    dd = Math::sqrt(dl2)
    h = h+dh
    if false then
      print "dx,dy,dz=#{dx},#{dy},#{dz}\n"
      print "rhat=#{x/r},#{y/r},#{z/r}\n"
    end
    hv.push([h,dh,dv,dd])
    #print "dh,dv=#{dh},#{dv}\n"
  end
  x,y,z=x2,y2,z2
  i = i+1
}

# filtering to get rid of artifacts of bad digital elevation model, which have a big effect
# on calculations of gain

osc_h = 500 # typical wavelength, in meters, of bogus oscillations
hv2 = []
hv.each { |a|
  h,dh,dv,dd = a

  if false then
  h0 = a[0]
  hv.each { |b|
    h,dh,dv,dd = b
    if Math::abs(h-h0<osc_h/2.0) then end
  }
  end

  hv2.push([dh,dv,dd])
}

# integrate...
h = 0 # total horizontal distance
v = 0 # total vertical distance (=0 at end of a loop)
d = 0 # total distance along the slope
gain = 0 # total gain
hv2.each { |a|
  dh,dv,dd = a
  h = h+dh
  v = v+dv
  d = d+dd
  if dv>0 then gain=gain+dv end
  csv = csv + "#{"%9.2f" % [h]},#{"%9.2f" % [v]},#{"%7.2f" %  [dh]},#{"%7.2f" %  [dv]}\n"
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
print "horizontal distance = #{"%6.2f" % [h]} #{h_unit}\n"
print "slope distance = #{"%6.2f" % [d]} #{h_unit}\n"
print "gain = #{"%5.0f" % [gain]} #{v_unit}\n"

File.open('kcals.csv','w') { |f| 
  f.print csv
}
