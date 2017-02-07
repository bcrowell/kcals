#!/usr/bin/ruby

require 'json'
require 'csv' # standard ruby library

# See README.md for documentation.

# wish list:
#   out and back option/detection

#=========================================================================
# @@ main
#=========================================================================

def main

  $cgi = ENV.has_key?("CGI")

  init_globals
  command_line_params = ARGV
  input_file = get_parameters($cgi,command_line_params)
  if $cgi then Dir.chdir("kcals_scratch") end
  path = get_track(input_file)
    # path = array of [lat,lon,altitude], in units of degrees, degrees, and meters
    # may have side-effect of creating temp files in cwd

  sanity_check_lat_lon_alt(path)
  box = get_lat_lon_alt_box(path) # box=[lat_lo,lat_hi,lon_lo,lon_hi,alt_lo,alt_hi]

  orig_n = path.length

  path = add_resolution_and_check_size_limit(path,box)
  path = add_dem_or_warn_if_appropriate(path,box)
  cartesian = to_cartesian(path)
    # cartesian = array of [r,x,y,z]

  hv = integrate_horiz_and_vert(cartesian)
    # list of [horiz,vert] positions

  # get rid of bogus fluctations
  r = filter_xyz(hv,cartesian,path)
  hv = r['hv']
  path = r['path']
  cartesian = r['cartesian']

  h = hv.last[0]
  stats = integrate_gain_and_energy(hv)
  stats['h'] = h
  stats['orig_n'] = orig_n
  stats['orig_resolution'] = h/orig_n

  if !$cgi then make_path_csv_and_json(path,cartesian,box) end
  if !$cgi then make_profile_csv(hv) end
  print_stats(stats)

  clean_up_temp_files

end

#=========================================================================
# @@ helper routines for main
#=========================================================================

def print_stats(stats)
  h,c,d,gain,i_rms,e_q = stats['h'],stats['c'],stats['d'],stats['gain'],stats['i_rms'],stats['e_q']
  iota_mean,iota_rms,cf = stats['iota_mean'],stats['iota_rms'],stats['cf']
  orig_n,orig_resolution,baumel_si = stats['orig_n'],stats['orig_resolution'],stats['baumel_si']
  h_raw = h
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
  eq_kcals = e_q*0.000239006
  if $verbosity>=2 then
    print "units=#{$metric ? "metric" : "US"}, #{$running ? "running" : "walking"}, weight=#{$body_mass} kg, filtering=#{$osc_h} m, format=#{$format}\n"
  end
  if $verbosity>0 then
    print "horizontal distance = #{"%.2f" % [h]} #{h_unit}\n"
    print "slope distance = #{"%.2f" % [d]} #{h_unit}\n"
    print "gain = #{"%.0f" % [gain]} #{v_unit}\n"
    print "cost = #{"%.0f" % [kcals]} kcals\n"
    print "CF (fraction of effort due to climbing) = #{"%4.f" % [cf*100.0]} %\n"
    if $verbosity>=3 then
      print "i_rms = #{"%.4f" % [i_rms]}\n"
      print "baumel_si = #{baumel_si} m\n"
      print "E_q = #{"%.0f" % [eq_kcals]} kcals\n"
      print "iota_mean = #{"%.4f" % [iota_mean]}\n"
      print "iota_sd = #{"%.4f" % [iota_rms]}\n"
      print "orig_n = #{orig_n}\n"
      print "resolution ~ orig_n/distance = #{"%.2f" % [orig_resolution]} m\n"
    end
  else
    print JSON.generate({
                   'horiz'=>("%.2f" % [h]),          'horiz_unit'=>h_unit,
                   'slope_distance'=>("%.2f" % [d]),
                   'gain'=>("%.0f" % [gain]),        'vert_unit'=>v_unit,
                   'cost'=>("%.0f" % [kcals]),
                   'i_rms'=>("%.4f" % [i_rms]),
                   'cf'=>("%4.2f" % [cf]),
                   'warnings'=>$warnings
             })+"\n"
  end
end

def get_track(input_file)
  if input_file.nil?
    if $stdin.isatty then fatal_error("This program reads a track from standard input in a format such as KML. For documentation, see https://github.com/bcrowell/kcals") end
    data = $stdin.gets(nil) # slurp all of stdin until end of file
  else
    data = slurp_file(input_file)
  end
  path = read_track($format,data)
  if path.length==0 then fatal_error("error, no points read successfully from input; usually this means you specified the wrong format") end
  return path
end

def init_globals
  $cgi = ENV.has_key?("CGI")

  $metric = false
  $running = true # set to false for walking
  $body_mass = 66 # in kg, =145 lb
  $osc_h = 250 # typical wavelength, in meters, of bogus oscillations in height data
              # calculated gain is very sensitive to this
              # putting in this value, which I estimated by eye from a graph, seems to reproduce
              # mapmyrun's figure for total gain
  $format = 'kml' # see README.md for legal values
  $dem = false # attempt to download DEM if absent from input?
  $verbosity = 2 # can go from 0 to 4; 0 means just to output data for use by a script
                 # at level 3, we get extra stats printed out
                 # at level 4, when we shell out, stderr and stdout get displayed
                 # level 0 means just output some json for use by a script
  $resolution = 30 # The path may contain long pieces that look like straight lines on a map, but are actually
                   # jagged in terms of elevation profile. Interpolate the polyline to make segments no longer
                   # than (approximately) this value, in meters. Default of 30 meters is SRTM's resolution.
  $force_dem = false # download DEM data even if elevations are present in the input file, for the reason
                     # described above in the comment describing $resolution
  $xy_filter = 30.0 # meters
  $method = 1 # 1 means new filtering method

  $server_max = 70000.0 # rough maximum, in meters, on size of routes for CGI version, to avoid overload
  $server_max_points = 2000 # and max number of points

  $warnings = []
  $warned_big_delta = false

  $temp_files = []

end

def make_path_csv_and_json(path,cartesian,box)

  lat_lo,lat_hi,lon_lo,lon_hi,alt_lo,alt_hi = box

  path_csv = "lat,lon,alt,x,y,z\n"
  i = 0
  z0 = cartesian[0][3] # initial point is (0,0,r); subtract this z0 to make it more readable
  path_data = []
  path.each { |p|
    lat,lon,alt = p # in degrees, degrees, meters
    cart = cartesian[i]
    x,y,z = [fmt_cart(cart[1]),fmt_cart(cart[2]),fmt_cart(cart[3]-z0)]
    path_csv = path_csv + "#{lat},#{lon},#{alt},#{x},#{y},#{z}\n"
    path_data.push([lat,lon,alt,x.to_f,y.to_f,z.to_f])
    i = i+1
  }
  File.open('path.csv','w') { |f| 
    f.print path_csv
  }
  File.open('path.json','w') { |f| 
    f.print JSON.generate({'box'=>box,'r'=>earth_radius(lat_lo),'z0'=>z0,'path'=>path_data})
  }

end

def fmt_cart(x) # x is a coordinate in meters; format for spreadsheet output
  return "%.2f" % [x]
end

def make_profile_csv(hv)
  csv = "horizontal,vertical,dh,dv,i,iota\n"
  first = true
  old_h = 0
  old_v = 0
  hv.each { |a|
    h,v = a
    if !first then
      dh = h-old_h
      dv = v-old_v
      i = dv/dh
    else
      dh = 0.0
      dv = 0.0
      i=0.0
    end
    i = in_minetti_range(i) # sanity check, don't contaminate results with bogus stuff
    iota = i_to_iota(i)
    csv = csv + "#{"%9.2f" % [h]},#{"%9.2f" % [v]},#{"%7.2f" %  [dh]},#{"%7.2f" %  [dv]},#{"%7.5f" %  [i]},#{"%7.5f" %  [iota]}\n"
    old_h = h
    old_v = v
    first = false
  }
  File.open('profile.csv','w') { |f| 
    f.print csv
  }
end

#=========================================================================
# @@ integration of results
#=========================================================================

def integrate_gain_and_energy(hv)
  # integrate to find total gain, slope distance, and energy burned
  # returns {'c'=>c,'d'=>d,'gain'=>gain,'i_rms'=>i_rms,...}
  v = 0 # total vertical distance (=0 at end of a loop)
  d = 0 # total distance along the slope
  gain = 0 # total gain
  c = 0 # cost in joules
  first = true
  old_h = 0
  old_v = 0
  i_sum = 0.0
  i_sum_sq = 0.0
  iota_sum = 0.0
  iota_sum_sq = 0.0
  baumel_si = 0.0 # compute this directly as a check
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
      if dh>0 then baumel_si=baumel_si+dv**2/dh end
      if i>1.0 then i=1.0 end # sanity check, sometimes we get large bogus values that would mess up stats
      if i<-1.0 then i=-1.0 end # ...
      # In the following, weight by dh, although normally this doesn't matter because we make the
      # h intervals constant before this point.
      i_sum = i_sum + i*dh
      i_sum_sq = i_sum_sq + i*i*dh
      iota = i_to_iota(i)
      iota_sum = iota_sum + iota*dh
      iota_sum_sq = iota_sum_sq + iota*iota*dh
      c = c+dd*$body_mass*minetti(i)
           # in theory it matters whether we use dd or dh here; I think from Minetti's math it's dd
    end
    old_h = h
    old_v = v
    first = false
  }
  n = hv.length-1.0
  h = hv.last[0]-hv[0][0]
  i_rms = Math::sqrt(i_sum_sq/h - (i_sum/h)**2)
  iota_mean = iota_sum/h
  iota_rms = Math::sqrt(iota_sum_sq/h - (iota_sum/h)**2)
  i_mean = (hv.last[1]-hv[0][1])/h
  i0,c0,c2,b0,b1,b2 = minetti_quadratic_coeffs()
  e_q = h*$body_mass*(b0+b1*i_mean+b2*i_rms)
  cf = (c-h*$body_mass*minetti(0.0))/c
  return {'c'=>c,'d'=>d,'gain'=>gain,'i_rms'=>i_rms,'i_mean'=>i_mean,'e_q'=>e_q,
           'iota_mean'=>iota_mean,'iota_rms'=>iota_rms,'cf'=>cf,'baumel_si'=>baumel_si}
end

def integrate_horiz_and_vert(cartesian)
  # definitions of variables:
  #   h,v,d are cumulative horiz, vert, and slope distance
  #   their increments are dh,dv,dd
  # returns list of [h,v]
  # May have side-effect of warning about big jumps in data that don't make sense.
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
      q = dl2-dv*dv
      if q>=0.0 then dh = Math::sqrt(q) else dh=0.0 end # horizontal distance
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
  return hv
end

#=========================================================================
# @@ filtering of tracks
#=========================================================================

def filter_xyz(hv0,cartesian0,path0)
  # hv = list of [horiz,vert] positions
  # cartesian = array of [r,x,y,z]
  # path = array of [lat,lon,altitude], in units of degrees, degrees, and meters
  res = 10 # meters; do an initial interpolation so that all points are this far apart in terms of the h
          # variable calculated from the initial iteration; make this small because fft is efficient,
          # and we don't want funky artifacts just because we have to make evenly spaced points for fft.
          # This should be much smaller than $resolution.
  x = [] # x as a function of h, with even spacing
  y = []
  z = []
  h = hv0.last[0] # total horizontal distance, which we take as our independent variable
  n = (h/res).to_i+1
  # make n a power of 2
  n = 2**(Math.log2(h/res).floor)
  if n<(h/res).to_i || n<2 then n=n*2 end
  dh = h/n
  n0 = hv0.length
  j=0
  0.upto(n-1) { |i|
    h = i*dh
    h1 = h2 = nil
    loop do # if the point we want doesn't lie in the current segment, bump it up
      h1 = hv0[j][0]
      h2 = hv0[j+1][0]
      break if h2>=h || j>=n0-2
      j=j+1
    end
    if h2==h1 then s=0 else s=(h-h1)/(h2-h1) end
    x.push(linear_interp(cartesian0[j][1],cartesian0[j+1][1],s))
    y.push(linear_interp(cartesian0[j][2],cartesian0[j+1][2],s))
    z.push(linear_interp(cartesian0[j][3],cartesian0[j+1][3],s))
  }
  xy_window = ($xy_filter/dh).floor 
  x = do_filter(x,xy_window)
  y = do_filter(y,xy_window)
  z = do_filter(z,($osc_h/dh).floor)
  cartesian = []
  path = []
  lat0 = path0[0][0]
  lon0 = path0[0][1]
  alt0 = path0[0][2]
  0.upto(n-1) { |i|
    xx,yy,zz = x[i],y[i],z[i]
    r = Math::sqrt(xx*xx+yy*yy+zz*zz)
    cartesian[i] = [r,xx,yy,zz]
    # path = array of [lat,lon,altitude], in units of degrees, degrees, and meters
    path[i] = cartesian_to_spherical(xx,yy,zz,lat0,lon0,alt0)
  }
  hv = integrate_horiz_and_vert(cartesian)
  return {'hv'=>hv,'cartesian'=>cartesian,'path'=>path}
end

def do_filter(v0,w)
  if w<=1 then return v0 end
  # v0's length should be a power of 2 and >=2
  # w = width of rectangular window to convolve with; will be made even if it isn't
  # returns a fresh array, doesn't modify v0

  if w%2==1 then w=w+1 end

  # remove DC and detrend, so that start and end are both at 0
  #        -- https://www.dsprelated.com/showthread/comp.dsp/175408-1.php
  # After filtering, we put these back in.
  # v0 = original, which we don't touch
  # v = detrended
  # v1 = filtered
  # For the current method, it's only necessary that n is even, not a power of 2, and detrending
  # isn't actually needed.
  v = v0.dup
  n = v.length
  slope = (v.last-v[0])/(n.to_f-1.0)
  c = -v[0]
  0.upto(n-1) { |i|
    v[i] = v[i] - (c + slope*i)
  }

  # Copy the unfiltered data over as a default. On the initial and final portions, where part of the
  # rectangular kernel hangs over the end, we don't attempt to do any filtering. Using the filter
  # on those portions, even with appropriate normalization, would bias the (x,y) points, effectively
  # moving the start and finish line inward.
  v1 = v.dup

  # convolve with a rectangle of width w:
  sum = 0
  count = 0
  # Sum the initial portion for use in the average for the first filtered data point:
  sum_left = 0.0
  0.upto(w-1) { |i|
    break if i>n/2-1 # this happens in the unusual case where w isn't less than n; we're guaranteed that n is even
    sum_left = sum_left+v[i]
  }
  # the filter is applied to the middle portion, from w to n-w:
  if w<n then
    sum = sum_left
    w.upto(n) { |i|
      sum = sum + v[i]-v[i-w]
      j = i-w/2
      break if j>n-w
      if j>=w && j<=n-w then
        v1[j] = sum/w
      end
    }
  end

  # To avoid a huge discontinuity in the elevation when the filter turns on, turn it on gradually
  # in the initial and final segments of length w:
  # FIXME: leaves a small discontinuity
  sum_left = 0.0
  sum_right = 0.0
  nn = 0
  0.upto(2*w+1) { |i|
    break if i>n/2-1 # unusual case, see above
    j = n-i-1
    sum_left = sum_left+v[i]
    sum_right = sum_right+v[j]
    nn = nn+1
    if i%2==0 then
      ii = i/2
      jj = n-i/2-1
      v1[ii] = sum_left/nn
      v1[jj] = sum_right/nn
    end
  }

  # put DC and trend back in:
  0.upto(n-1) { |i|
    v1[i] = v1[i] + (c + slope*i)
  }
  return v1
end

def filter_elevation(hv)
  # hv = list of [horiz,vert] positions
  # filtering to get rid of artifacts of bad digital elevation model, which have a big effect
  # on calculations of gain
  # bug: this is an O(n^2) algorithm, can be made into O(n)
  hv2 = []
  hv.each { |a|
    h,v = a
    v_av = 0
    n_av = 0
    hv.each { |b|
      hh,vv = b
      if (hh-h).abs<($osc_h+0.01)/2.0 then
        v_av = v_av+vv
        n_av = n_av+1
      end
    }
    if n_av<1 then fatal_error("n_av<1?? at h,v=#{h},#{v}") end
    v = v_av/n_av
    hv2.push([h,v])
  }
  return hv2
end

def to_cartesian(path)
  cartesian = [] # array of [r,x,y,z]
  first = true
  lat0 = 0
  lon0 = 0
  path.each { |p|
    lat,lon,alt = p # in degrees, degrees, meters
    if first then lat0=lat; lon0=lon end
          # ... for convenience of visualization and interp, and also to fix radius of earth at initial value
    cart = spherical_to_cartesian(lat,lon,alt,lat0,lon0)
    cartesian.push(cart)
    first=false
  }
  return cartesian
end

def add_dem_or_warn_if_appropriate(path,box)
  lat_lo,lat_hi,lon_lo,lon_hi,alt_lo,alt_hi = box
  no_alt = alt_lo==0.0 && alt_hi==0.0
  if no_alt && !$dem then
    warning("The input file does not appear to contain any elevation data. Turn on the option 'dem' to try to download this.")
  end
  if $force_dem || (no_alt && $dem) then
    path = add_dem(path,box)
  end
  return path
end

def add_resolution_and_check_size_limit(path,box)
  # Break up long polyline segments into shorter ones by interpolation.
  # See comment near top of code where $resolution is defined to explain why.
  # If running as CGI, perform a rough estimate of the size of the dataset, and throw an error if too big.
  # Otherwise, return the new version of the path.

  lat_lo,lat_hi,lon_lo,lon_hi,alt_lo,alt_hi = box

  # For purposes of a couple of estimates, we don't need super accurate horizontal distances.
  # Just use these scale factors.
  r = earth_radius(lat_lo) # just need a rough estimate
  klat = (Math::PI/180.0)*r # meters per degree of latitude
  klon = klat*Math::cos(deg_to_rad(lat_lo)) # ... and longitude

  # Estimate size of job and DEM raster to make sure it isn't too ridiculous for CGI.
  h_diag = pythag(klat*(lat_hi-lat_lo),klon*(lon_hi-lon_lo))
  if h_diag>$server_max && $cgi then
    fatal_error("Sorry, your route covers too large a region for the server-based application.")
  end
  if h_diag>300000.0 then # more than 300 km
    fatal_error("Something is wrong, the diagonal measurement across the bounding box of your route appears to be #{h_diag/1000.0} km, which is unreasonably large.")
  end

  path2 = []
  i=0
  h_path = 0 # rough approximation to gauge load on server
  path.each { |p|
    path2.push(p)
    break if i>path.length-2
    lat,lon,alt = p
    p2 = path[i+1]
    lat2,lon2,alt2 = p2
    h = pythag(klat*(lat2-lat),klon*(lon2-lon))
    h_path = h_path + h
    if h_path>$server_max && $cgi then
      fatal_error("Sorry, your route is too long for the server-based application.")
    end  
    if h>$resolution then
      n = (h/$resolution).to_i+1
      1.upto(n-1) { |i| # we have i=0 and will later automatically get i=n; fill in i=1 to i=n-1
        s = (i.to_f)/(n.to_f)
        path2.push([linear_interp(lat,lat2,s),linear_interp(lon,lon2,s),linear_interp(alt,alt2,s)])
      }
    end
    i = i+1
  }

  if path.length>$server_max_points  && $cgi then
    fatal_error("Sorry, your route is too long for the server-based application.")                               
  end

  return path2
end

def add_dem(path,box)
  lat_lo,lat_hi,lon_lo,lon_hi,alt_lo,alt_hi = box
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
  if $verbosity>=4 then redir='' end
  cache_dir_option = ''
  if $cgi then # in command-line use, these get marked for deletion below, only after running the commands, so possible
               # error information is preserved
    $temp_files.push(temp_stderr)
    $temp_files.push(temp_stdout)
    cache_dir_option = "--cache_dir #{Dir.pwd}"
  end
  shell_out("eio #{cache_dir_option} clip -o #{temp_tif} --bounds #{box} #{redir}",
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
  last_ix = 0
  last_iy = 0
  i=0
  path2 = []
  path.each { |p|
    lat,lon,alt = p
    x = (lon-xllcorner)/cellsize # in array-index units, but floating point
    y = h-(lat-yllcorner)/cellsize
    if x<0.0 then x=0.0 end
    if x>w-1 then x=(w-1.0001).to_f end
    if y<0.0 then y=0.0 end
    if y>h-1 then y=(h-1.0001).to_f end
    z = interpolate_raster(z_data,x,y)
    path2[i] = [lat,lon,z]
    i=i+1
  }
  return path2
end

#=========================================================================
# @@ physiological model
#=========================================================================

# For the cr and cw functions, see Minetti, http://jap.physiology.org/content/93/3/1039.full

def minetti(i)
  if $running then return minetti_cr(i) else return minetti_cw(i) end
end

def i_to_iota(i)
  # convert i to a linearized scale iota, where iota^2=[C(i)-C(imin)]/c2 and sign(iota)=sign(i-imin)
  # The following are the minima of the Minetti functions.
  if $running then
    imin = -0.181355
    cmin = 1.781269
    c2=66.0
  else
    imin = -0.152526
    cmin= 0.935493
    c2=94.0
  end
  c=minetti(i) # automatically brings i in sane range if out of range
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

#=========================================================================
# @@ physics, geometry
#=========================================================================

def earth_radius(lat)
  # https://en.wikipedia.org/wiki/Earth_radius#Geocentric_radius
  a = 6378137.0 # earth's equatorial radius, in meters
  b = 6356752.3 # polar radius
  slat = Math::sin(deg_to_rad(lat))
  clat = Math::cos(deg_to_rad(lat))
  return Math::sqrt( ((a*a*clat)**2+(b*b*slat)**2) / ((a*clat)**2+(b*slat)**2)) # radius in meters
end

def cartesian_to_spherical(x,yy,zz,lat0,lon0,alt0)
  # returns [lat,lon,altitude], in units of degrees, degrees, and meters
  # see spherical_to_cartesian() for description of coordinate systems used and the transformations.
  r0 = earth_radius(lat0)
  slat0 = Math::sin(deg_to_rad(lat0))
  clat0 = Math::cos(deg_to_rad(lat0))
  r = Math::sqrt(x*x+yy*yy+zz*zz)
  alt = r-r0
  y =  clat0*yy+slat0*zz
  z = -slat0*yy+clat0*zz
  lat = rad_to_deg(Math::asin(y/r))
  lon = rad_to_deg(Math::atan2(x,z))+lon0
  return [lat,lon,alt]
end

def spherical_to_cartesian(lat,lon,alt,lat0,lon0)
  # inputs are in degrees, except for alt, which is in meters
  # The purpose of lat0 and lon0 is to do a rotation to make the cartesian coordinates easier to interpret.
  # outputs are in meters. We rotate to coordinate axes parallel to NSEWUD at initial point.
  # x=east, y=north, z=up
  # The z coordinate is always almost exactly equal to the radius of the earth.
  lat_rad = deg_to_rad(lat)
  lon_rad=deg_to_rad(lon-lon0)
  slat = Math::sin(lat_rad)
  slon = Math::sin(lon_rad)
  clat = Math::cos(lat_rad)
  clon = Math::cos(lon_rad)
  r0 = earth_radius(lat0)
        # Use initial latitude and keep r0 constant. If we let r0 vary, then we also need to figure
        # out the direction of the g vector in this model.
  r = r0+alt
  # Initially calculate it in coordinate axes where z points from earth's center to the point P on equator
  # nearest to the start, x points east from P (which we pretend is at lon=0), and y points toward
  # celestial pole.
  z = r*clat*clon
  x = r*clat*slon
  y = r*slat
  # Now rotate in the yz plane to get in coordinates parallel to NSEWUD at initial point.
  slat0 = Math::sin(deg_to_rad(lat0))
  clat0 = Math::cos(deg_to_rad(lat0))
  yy =  clat0*y-slat0*z
  zz =  slat0*y+clat0*z
  return [r,x,yy,zz]
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

#=========================================================================
# @@ reading input files
#=========================================================================

def read_track(format,data)
  if format=='kml' || format=='gpx' then return read_track_through_gpsbabel(format,data) end
  if format=='csv' then                  return read_track_from_csv(data) end
  if format=='txt' then                  return read_track_from_text(data) end
  fatal_error("unrecognized format: #{format}")
end

def read_track_through_gpsbabel(format,kml)
  if $cgi then temp = "temp#{Process.pid}" else temp="temp" end
  temp_csv = "#{temp}_convert.csv"
  temp_kml = "#{temp}_convert.#{format}"
  $temp_files.push(temp_csv)
  $temp_files.push(temp_kml)
  open(temp_kml,'w') { |f| f.print kml }
  ok,err = shell_out_low_level("gpsbabel -t -i #{format} -f #{temp_kml} -o unicsv -F #{temp_csv}",'',false)
  if !ok then fatal_error("syntax error on KML input; this usually means you specified the wrong format.\n#{err}") end
  return import_csv(temp_csv)
end

def read_track_from_csv(csv)
  if $cgi then temp = "temp#{Process.pid}" else temp="temp" end
  temp_csv = "#{temp}_convert.csv"
  $temp_files.push(temp_csv)
  open(temp_csv,'w') { |f| f.print csv }
  return import_csv(temp_csv)
end

def read_track_from_text(data)
  path = []
  data.each_line { |line|
    if line=~/\AT\s+([^\s]+)\s+([^\s]+)\s+([^\s]+)/ then
      lat,lon,alt = $1.to_f,$2.to_f,$3.to_f # in degrees, degrees, meters
      path.push([lat,lon,alt])
    end
  }
  return path
end

# import the unicsv format written by gpsbabel:
def import_csv(file)
  # csv file looks like:
  # No,Latitude,Longitude,Name,Altitude,Description
  # 1,37.732511,-119.558805,"Happy Isles Trail Head",0.0,"Happy Isles Trail Head"
  a = CSV.open(file, 'r', :headers => true).to_a.map { |row| row.to_hash }
  #          ... http://technicalpickles.com/posts/parsing-csv-with-ruby/
  # output array of hashes now looks like (represented as JSON):
  #   [{"No":"1","Latitude":"37.732511","Longitude":"-119.558805","Name":"Happy Isles Trail Head","Altitude":"0.0"...
  path = []
  a.each { |h|
    alt = 0.0
    if h.has_key?('Altitude') then alt=h['Altitude'].to_f end
    path.push([h['Latitude'].to_f,h['Longitude'].to_f,alt])
  }
  return path
end

def sanity_check_lat_lon_alt(path)
  path.each { |p|
    lat,lon,alt = p
    if lat<-90 || lat>90 then fatal_error("illegal latitude, #{lat}, in input") end
    if lon<-360 || lon>360 then fatal_error("illegal longitude, #{lon}, in input") end
    if alt<-10000.0 || alt>10000.0 then fatal_error("illegal altitude, #{alt}, in input") end
  }
end

def get_lat_lon_alt_box(path)
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
  return [lat_lo,lat_hi,lon_lo,lon_hi,alt_lo,alt_hi]
end

#=========================================================================
# @@ low-level file access, shell, command-line arguments
#=========================================================================

# returns contents or nil on error; for more detailed error reporting, see slurp_file_with_detailed_error_reporting()
def slurp_file(file)
  x = slurp_file_with_detailed_error_reporting(file)
  return x[0]
end

# returns [contents,nil] normally [nil,error message] otherwise
def slurp_file_with_detailed_error_reporting(file)
  begin
    File.open(file,'r') { |f|
      t = f.gets(nil) # nil means read whole file
      if t.nil? then t='' end # gets returns nil at EOF, which means it returns nil if file is empty
      return [t,nil]
    }
  rescue
    return [nil,"Error opening file #{file} for input: #{$!}."]
  end
end

def clean_up_temp_files
  shell_out("rm -f #{$temp_files.join(' ')}") if $temp_files.length>0
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
  shell_out_low_level(c,additional_error_info,true)
end

def shell_out_low_level(c,additional_error_info,die_on_error)
  redir = ''
  if $cgi then redir='1>/dev/null 2>/dev/null' end
  full_command = "#{c} #{redir}"
  ok = system(full_command)
  return [true,''] if ok
  message = "error on shell command #{full_command}, #{$?}\n#{additional_error_info}"
  if die_on_error then
    fatal_error(message)
  else
    return [false,message]
  end
end

def set_param(par,value,where,s)
  recognized = false
  if par=='metric' then recognized=true; $metric=(value.to_i==1) end
  if par=='running' then recognized=true; $running=(value.to_i==1) end
  if par=='weight' then recognized=true; $body_mass=value.to_f end
  if par=='filtering' then recognized=true; $osc_h=value.to_f end
  if par=='xy_filtering' then recognized=true; $xy_filter=value.to_f end
  if par=='dem' then recognized=true; $dem=(value.to_i==1) end
  if par=='verbosity' then recognized=true; $verbosity=value.to_i end
  if par=='resolution' then recognized=true; $resolution=value.to_f end
  if par=='force_dem' then recognized=true; $force_dem=(value==1) end
  if par=='infile' then recognized=true; $infile=value end
  if par=='format' then
    recognized=true
    $format=value
    explicit_format = true
  end
  if !recognized then fatal_error("illegal parameter #{par}#{where}:\n#{s}") end
end

def handle_param(s,where)
  explicit_format = false
  if s=~/\A\s*(\w+)\s*=\s*([^\s]+)\Z/ then
    par,value = $1,$2
    explicit_format = set_param(par,value,where,s)
    return explicit_format
  else
    fatal_error("illegal syntax#{where}:\n#{s}")
  end
end

def get_parameters(cgi,command_line_parameters)
  # cgi = boolean, are we running as a CGI?
  # as a side-effect, manipulates the globals that hold the parameters: $body_mass, etc.
  # looks for defaults in prefs file
  # returns name of input file, or nil if reading from stdin

  # If running as CGI, then for security we just take all the arguments from a JSON string passed through popen2.
  # One of the parameters should be infile.
  if cgi then
    params = JSON.parse(command_line_parameters[0])
    params.each_key {|par| set_param(par,params[par],'','')}
    return $infile
  end

  # Not running as CGI...
  input_file = nil # reading from stdin by default
  if command_line_parameters.length>=1 && !(command_line_parameters.last=~/\=/) then
    # If the final command-line argument doesn't have an equals sign in it, interpret it as the input file.
    input_file = command_line_parameters.pop
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
    warning("Warning: File #{prefs} doesn't exist, so default values have been assumed for all parameters.")
  end
  # then override at command line:
  explicit_format = false
  command_line_parameters.each { |p|
    explicit_format = explicit_format | handle_param(p,'') 
  }
  if !explicit_format && !input_file.nil? then
    # attempt to guess format from name of input file
    if input_file=~/\.(\w+)\Z/ then
      ext = $1
      if ext=='csv' || ext=='kml' || ext=='gpx' || ext=='txt' then $format=ext end
    end
  end
  return input_file
end

#=========================================================================
# @@ low-level math
#=========================================================================

def deg_to_rad(x)
  return 0.0174532925199433*x
end

def rad_to_deg(x)
  return x/0.0174532925199433
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

def linear_interp(x1,x2,s)
  return x1+s*(x2-x1)
end


#=========================================================================
# @@ execute main()
#=========================================================================

main
