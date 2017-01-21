#!/usr/bin/ruby

require 'json'

# See README.md for documentation.

# wish list:
#   out and back option/detection

if $stdin.isatty then
  print "This program reads a track from standard input in a format such as KML. For documentation, see\n"
  print "https://github.com/bcrowell/kcals\n"
  exit(-1)
end


command_line_parameters=ARGV

$cgi = ENV.has_key?("CGI")

$metric = false
$running = true # set to false for walking
$body_mass = 66 # in kg, =145 lb
$osc_h = 500 # typical wavelength, in meters, of bogus oscillations in height data
            # calculated gain is very sensitive to this
            # putting in this value, which I estimated by eye from a graph, seems to reproduce
            # mapmyrun's figure for total gain
$format = 'kml' # can be kml or text, where text means the output format of http://www.gpsvisualizer.com/elevation
$dem = false # attempt to download DEM if absent from input?
$verbosity = 2 # can go from 0 to 3; 0 means just to output data for use by a script
               # at level 3, when we shell out, stderr and stdout get displayed
               # level 0 means just output some json for use by a script
$resolution = 30 # The path may contain long pieces that look like straight lines on a map, but are actually
                 # jagged in terms of elevation profile. Interpolate the polyline to make segments no longer
                 # than (approximately) this value, in meters. Default of 30 meters is SRTM's resolution.
$force_dem = false # download DEM data even if elevations are present in the input file, for the reason
                   # described above in the comment describing $resolution

$warnings = []

def clean_up_temp_files
  shell_out("rm -f #{$temp_files.join(' ')}")
end

def fatal_error(message)
  if $verbosity>=1 && !$cgi then
    $stderr.print "kcals.rb: #{$verb} fatal error: #{message}\n"
  else
    print JSON.generate({'error'=>message})+"\n"
  end
  exit(-1)
end

def warning(message)
  if $verbosity>=1 && !$cgi then
    $stderr.print "kcals.rb: #{$verb} warning: #{message}\n"
  else
    $warnings.push(message)
  end
end

def shell_out(c,additional_error_info='')
  ok = system(c)
  return true if ok
  fatal_error("error on shell command #{c}, #{$?}\n#{additional_error_info}")
end

$warned_big_delta = false

$temp_files = []

def handle_param(s,where)
  if s=~/\A\s*(\w+)\s*=\s*([^\s]+)\Z/ then
    par,value = $1,$2
    recognized = false
    if par=='metric' then recognized=true; $metric=(value.to_i==1) end
    if par=='running' then recognized=true; $running=(value.to_i==1) end
    if par=='weight' then recognized=true; $body_mass=value.to_f end
    if par=='filtering' then recognized=true; $osc_h=value.to_f end
    if par=='format' then recognized=true; $format=value end
    if par=='dem' then recognized=true; $dem=(value.to_i==1) end
    if par=='verbosity' then recognized=true; $verbosity=value.to_i end
    if par=='resolution' then recognized=true; $resolution=value.to_f end
    if par=='force_dem' then recognized=true; $force_dem=(value==1) end
    if !recognized then fatal_error("illegal parameter #{par}#{where}:\n#{s}") end
  else
    fatal_error("illegal syntax#{where}:\n#{s}")
  end
end

# first read from prefs file:
if !$cgi then
  prefs = "#{Dir.home}/.kcals"
  begin
    open(prefs,'r') { |f|
      f.each_line {|line|
        next if line=~/\A\s*\Z/
        handle_param(line," in #{prefs}")
      }
    }
  rescue
    warning("Warning: File #{prefs} doesn't exist, so default values have been assumed for all parameters.")
  end
end
# then override at command line:
command_line_parameters.each { |p| handle_param(p,'') }

if $verbosity>=2 then
  print "units=#{$metric ? "metric" : "US"}, #{$running ? "running" : "walking"}, weight=#{$body_mass} kg, filtering=#{$osc_h} m, format=#{$format}\n"
end

# For the cr and cw functions, see Minetti, http://jap.physiology.org/content/93/3/1039.full

def minetti(i)
  if $running then return minetti_cr(i) else return minetti_cw(i) end
end

def in_minetti_range(i)
  return -0.5 if i<-0.5
  return 0.5 if i>0.5
  return i
end

def minetti_cr(i)
  # i = gradient
  # cr = cost of running, in J/kg.m
  i = in_minetti_range(i)
  return 155.4*i**5-30.4*i**4-43.3*i**3+46.3*i**2+19.5*i+3.6
  # note that the 3.6 is different from their best value of 3.4 on the flats, i.e., the polynomial isn't a perfect fit
end

def minetti_cw(i)
  # i = gradient
  # cr = cost of walking, in J/kg.m
  i = in_minetti_range(i)
  return 280.5*i**5-58.7*i**4-76.8*i**3+51.9*i**2+19.6*i+2.5
end

def deg_to_rad(x)
  return 0.0174532925199433*x
end

def earth_radius(lat,lon)
  # https://en.wikipedia.org/wiki/Earth_radius#Geocentric_radius
  a = 6378137.0 # earth's equatorial radius, in meters
  b = 6356752.3 # polar radius
  slat = Math::sin(deg_to_rad(lat))
  clat = Math::cos(deg_to_rad(lat))
  return Math::sqrt( ((a*a*clat)**2+(b*b*slat)**2) / ((a*clat)**2+(b*slat)**2)) # radius in meters
end

def spherical_to_cartesian(lat,lon,alt,lat0,lon0)
  # inputs are in degrees, except for alt, which is in meters
  # The purpose of lat0 and lon0 is to do a rotation to make the cartesian coordinates easier to interpret.
  # outputs are in meters
  lat_rad = deg_to_rad(lat)
  rotate = true # rotate to tangent coordinates?
  lonx = lon
  if rotate then lonx=lon-lon0 end
  lon_rad = deg_to_rad(lonx)
  slat = Math::sin(lat_rad)
  slon = Math::sin(lon_rad)
  clat = Math::cos(lat_rad)
  clon = Math::cos(lon_rad)
  r0 = earth_radius(lat0,lon0)
        # Use initial latitude and keep r0 constant. If we let r0 vary, then we also need to figure
        # out the direction of the g vector in this model.
  r = r0+alt
  x = r*clat*clon
  y = r*clat*slon
  z = r*slat
  xx = x
  zz = z
  if rotate then
    slat0 = Math::sin(deg_to_rad(lat0))
    clat0 = Math::cos(deg_to_rad(lat0))
    xx =  clat0*x+slat0*z
    zz = -slat0*x+clat0*z
  end
  return [r,xx,y,zz]
end

def pythag(x,y)
  return Math::sqrt(x*x+y*y)
end

def interpolate_square(x,y,z00,z10,z01,z11)
  root2 = Math::sqrt(2.0)
  w00 = (root2-pythag(x,y)).abs
  w10 = (root2-pythag(x-1.0,y)).abs
  w01 = (root2-pythag(x,y-1.0)).abs
  w11 = (root2-pythag(x-1.0,y-1.0)).abs
  norm = w00+w10+w01+w11
  z = (z00*w00+z10*w10+z01*w01+z11*w11)/norm
  return z
end

def interpolate_raster(z,x,y)
  # z = array[iy][ix]
  # x,y = floating point, in array-index units
  ix = x.to_i
  iy = y.to_i
  fx = x-ix # fractional part
  fy = y-iy
  z = interpolate_square(fx,fy,z[iy][ix],z[iy][ix+1],z[iy+1][ix],z[iy+1][ix+1])  
  return z
end

path = []
format_recognized = false

if $format=='kml' then
  format_recognized = true
  kml = $stdin.gets(nil) # slurp all of stdin until end of file
  # xml; relevant part of mapmyroute output looks like this:
  #    <coordinates>
  #     -117.96391,33.88906,0 -117.96531,33.88905,0 
  #    </coordinates>
  # GPSbabel output looks like this:
  #     34.26610, -117.63361, 
  #     34.26447, -117.63266, 
  # Bug: the following doesn't really parse xml correctly, may not work for xml output that doesn't look like I expect.
  # Should probably look for coords inside <Folder id="Tracks">, but instead just look for one that seems long enough,
  # since the coords I don't want are single points
  if kml.nil? then fatal_error("empty input file") end
  kml.gsub!(/\n/,' ') # smash everything to one line
  coords_text = ''
  if kml=~/<coordinates>([^<]{100,})<\/coordinates>/ then # at least 100 characters for the actual path
    coords_text = $1
    coords_text.scan(/([0-9\.\-]+),\s*([0-9\.\-]+),\s*([0-9\.\-]*)\s*/).each { |c|
      lon,lat,alt = c
      if alt=='' then alt='0.0' end
      path.push([lat.to_f,lon.to_f,alt.to_f])
    }
  else
    fatal_error("no coordinates element found in input KML file; usually this means that you selected the wrong format")
  end
end

if $format=='text' then
  format_recognized = true
  $stdin.each_line { |line|
    if line=~/\AT\s+([^\s]+)\s+([^\s]+)\s+([^\s]+)/ then
      lat,lon,alt = $1.to_f,$2.to_f,$3.to_f # in degrees, degrees, meters
      path.push([lat,lon,alt])
    end
  }
end

if !format_recognized then fatal_error("unrecognized format: #{$format}") end

path.each { |p|
  lat,lon,alt = p
  if lat<-90 || lat>90 then fatal_error("illegal latitude, #{lat}, in input") end
  if lon<-360 || lon>360 then fatal_error("illegal longitude, #{lon}, in input") end
  if alt<-10000.0 || alt>10000.0 then fatal_error("illegal altitude, #{alt}, in input") end
}
lon_lo = 999.9
lon_hi = -999.9
lat_lo = 999.9
lat_hi = -999.9
alt_lo = 10000.0
alt_hi = -10000.0
path.each { |p|
  lat,lon,alt = p
  lon_lo=lon if lon < lon_lo
  lon_hi=lon if lon > lon_hi
  lat_lo=lat if lat < lat_lo
  lat_hi=lat if lat > lat_hi
  alt_lo=alt if alt < alt_lo
  alt_hi=alt if alt > alt_hi
}

def linear_interp(x1,x2,s)
  return x1+s*(x2-x1)
end

# Break up long polyline segments into shorter ones by interpolation.
# See comment near top of code where $resolution is defined to explain why.
path2 = []
# For this purpose, we don't need super accurate horizontal distances. Just estimate these using
# a couple of scale factors.
r = earth_radius(lat_lo,lon_lo) # just need a rough estimate
klat = (Math::PI/180.0)*r # meters per degree of latitude
klon = klat*Math::cos(deg_to_rad(lat_lo)) # ... and longitude
i=0
path.each { |p|
  path2.push(p)
  break if i>path.length-2
  lat,lon,alt = p
  p2 = path[i+1]
  lat2,lon2,alt2 = p2
  h = pythag(klat*(lat2-lat),klon*(lon2-lon))
  if h>$resolution then
    n = (h/$resolution).to_i+1
    1.upto(n-1) { |i| # we have i=0 and will later automatically get i=n; fill in i=1 to i=n-1
      s = (i.to_f)/(n.to_f)
      path2.push([linear_interp(lat,lat2,s),linear_interp(lon,lon2,s),linear_interp(alt,alt2,s)])
    }
  end
  i = i+1
}
path = path2

no_alt = alt_lo==0.0 && alt_hi==0.0
if no_alt && !$dem then
  warning("The input file does not appear to contain any elevation data. Turn on the option 'dem' to try to download this.")
end
if $force_dem || (no_alt && $dem) then
  if $cgi then temp = "temp#{Process.pid}" else temp="temp" end
  temp_tif = "#{temp}.tif"
  temp_aig = "#{temp}.aig"
  temp_stderr = "#{temp}.stderr"
  temp_stdout = "#{temp}.stdout"
  $temp_files.push(temp_tif)
  $temp_files.push(temp_aig)
  $temp_files.push("#{temp}.prj")
  $temp_files.push("#{temp}.aig.aux.xml")
  box = "#{lon_lo} #{lat_lo} #{lon_hi} #{lat_hi}"
  if $verbosity>=2 then $stderr.print "Downloading elevation data.\n" end
  redir = "1>#{temp_stdout} 2>#{temp_stderr}";
  if $verbosity>=3 then redir='' end
  save_dir = Dir.pwd
  if $cgi then Dir.chdir("kcals_scratch") end
  shell_out('echo "foo" >a.a') # qwe
  if $cgi then # in command-line use, these get marked for deletion below, only after running the commands, so possible
               # error information is preserved
    $temp_files.push(temp_stderr)
    $temp_files.push(temp_stdout)
  end
  shell_out("eio --cache_dir #{Dir.pwd} clip -o #{temp_tif} --bounds #{box} #{redir}",
            "Information about the errors may be in the files temp*.stdout and temp*.stderr.") 
          # box is sanitized, because all input have been through .to_f
  shell_out("gdal_translate -of AAIGrid -ot Int32 #{temp_tif} #{temp_aig} #{redir}")
  if !$cgi then
    $temp_files.push(temp_stderr) # mark them for deletion now, since no interesting error messages in them
    $temp_files.push(temp_stdout)
  end
  # read headers first
  aig_headers = Hash.new
  File.open(temp_aig,'r') { |f|
    while(line = f.gets) != nil
      break unless line=~/\A[a-zA-Z]/ # done with headers
      if line=~/(\w+)\s+([\.\-0-9]+)/ then
        key,value = $1,$2
        aig_headers[key] = value
      else
        warning("unrecognized line #{line} in #{temp_aig}")
      end
    end    
  }
  w = aig_headers['ncols'].to_i
  h = aig_headers['nrows'].to_i
  xllcorner = aig_headers['xllcorner'].to_f # longitude in degrees
  yllcorner = aig_headers['yllcorner'].to_f # latitude in degrees
  cellsize = aig_headers['cellsize'].to_f # size of each pixel in degrees
  if w.nil? or h.nil? or xllcorner.nil? or yllcorner.nil? or cellsize.nil? then
    fatal_error("error reading header lines from file #{temp_aig}, headers=#{aig_headers}")
  end
  z_data = nil
  File.open(temp_aig,'r') { |f|
    z_data = Array.new(h) { |i| Array.new(w) { |j| 0 }} # z_data[y][x], y going from top to bottom
    ix = 0
    iy = 0
    while(line = f.gets) != nil
      next if line=~/\A[a-zA-Z]/ # skip headers
      line.split(/\s+/).each { |z|
        next unless z=~/[0-9]/
        z_data[iy][ix] = z.to_f
        ix = ix+1
        if ix>=w then ix=0; iy=iy+1 end
      }
    end
  }
  if $cgi then Dir.chdir(save_dir) end
  last_ix = 0
  last_iy = 0
  i=0
  path.each { |p|
    lat,lon,alt = p
    x = (lon-xllcorner)/cellsize # in array-index units, but floating point
    y = h-(lat-yllcorner)/cellsize
    if x<0.0 then x=0.0 end
    if x>w-1 then x=(w-1.0001).to_f end
    if y<0.0 then y=0.0 end
    if y>h-1 then y=(h-1.0001).to_f end
    z = interpolate_raster(z_data,x,y)
    path[i] = [lat,lon,z]
    i=i+1
  }
end

csv = "horizontal,vertical,dh,dv\n"
path_csv = "lat,lon,alt,x,y,z\n"

cartesian = [] # array of [r,x,y,z]
first = true
lat0 = 0
lon0 = 0
path.each { |p|
  lat,lon,alt = p # in degrees, degrees, meters
  if first then lat0=lat; lon0=lon end
        # ... for convenience of visualization and interp, and also to fix radius of earth at initial value
  cart = spherical_to_cartesian(lat,lon,alt,lat0,lon0)
  path_csv = path_csv + "#{lat},#{lon},#{alt},#{cart[0]},#{cart[1]},#{cart[2]}\n"
  cartesian.push(cart)
  first=false
}
n = cartesian.length

if !$cgi then
  File.open('path.csv','w') { |f| 
    f.print path_csv
  }
end

#print "points read = #{n}\n"
if n==0 then fatal_error("error, no points read successfully from input; usually this means you specified the wrong format") end

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
  if i>0 && dh>10000.0 then
    if !$warned_big_delta then
      warning("Two successive points are more than 10 km apart horizontally: dx=#{dx}, dy=#{dy}, dx=#{dz}.")
      $warned_big_delta = true
    end
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
    if (hh-h).abs<($osc_h+0.01)/2.0 then
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
if $verbosity>0 then
  print "horizontal distance = #{"%.2f" % [h]} #{h_unit}\n"
  print "slope distance = #{"%.2f" % [d]} #{h_unit}\n"
  print "gain = #{"%.0f" % [gain]} #{v_unit}\n"
  print "cost = #{"%.0f" % [kcals]} kcals\n"
else
  print JSON.generate({'horiz'=>("%.2f" % [h]),'horiz_unit'=>h_unit,
                 'slope_distance'=>("%.2f" % [d]),
                 'gain'=>("%.0f" % [gain]),'vert_unit'=>v_unit,
                 'cost'=>("%.0f" % [kcals]),
                 'warnings'=>$warnings
           })+"\n"
end

if !$cgi then
  File.open('profile.csv','w') { |f| 
    f.print csv
  }
end

clean_up_temp_files
