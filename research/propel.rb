#!/usr/bin/ruby

require 'json'
require 'csv' # standard ruby library

$lib = "../lib"

require_relative "#{$lib}/geometry"
require_relative "#{$lib}/low_level_math"
require_relative "#{$lib}/system"

# usage:
#   ./propel.rb '{"lati":34.26645,"loni":-117.62755,"h":10.0,"g":10.0,"w":"hann","dparmax":0.25,"eps":3.0,"skip":10,"bump":1}' baldy/preprocessed/baldy_0*.json
# First arg is parameters, formatted as a JSON hash.
# The rest are files giving polygonal approximations to gps tracks. They should
# contain columns x and y -- maybe z? Can contain other columns.
# Writes path.json and path.csv.
# parameters:
#   lati,loni -- initial lat and lon, in degrees
#   h -- in meters, sets the width of the window for averaging of paths
#   g -- in meters, sets inverse strength of transverse force
#   w -- 'hann' or 'square'
#   dparmax -- unitless; prefer points on a path that differ in estimated parameter by less than this fractional amount;
#              to turn off this feature, set dparmax=1.0; default=1.0; useful for out-and-back or lollipop routes
#   prefer_forward -- try not to go back to an earlier index on a path; boolean 0,1; default=1
#   eps -- distance to move in meters at each step
#   skip -- e.g., if this is 10, then only write every 10th point to the output files
#   bump -- boolean; if 1, then try to move past points with f=0
#   verbosity -- 0 to 3

$verbosity = 0

def main
  params = JSON.parse(ARGV.shift)
  input_files = ARGV

  lat0 = nil
  lon0 = nil
 
  paths = []
  result = nil  
  input_files.each { |file|
    data = JSON.parse(slurp_file(file))
    # {"box":[34.266225,34.289151,-117.647213,-117.608728,0.0,0.0],"r":6371396.587202083,
    #  "lat0":34.266225,"lon0":-117.626925,
    #   "path":[[34.266225,-117.626925,1884.1385896780353,0.0,0.0,1884.14],...]}
    if result.nil? then result=data end # keep a copy of 1st path as template for output
    data2 = []
    data['path'].each { |p|
      data2.push({'p'=>[p[3],p[4]]})
    }
    paths.push(data2)
    if (!(lat0.nil?) && lat0!=data['lat0']) || (!(lon0.nil?) && lon0!=data['lon0']) then
      fatal_error("file #{file} is trying to change lat0 and lon0 from previously set values")
    end
    lat0 = data['lat0']
    lon0 = data['lon0']
  }

  box = get_bounding_box(paths)
  x_lo,x_hi,y_lo,y_hi = box

  # see comments at top of code for definitions of parameters
  lati = require_param(params,'lati') 
  loni = require_param(params,'loni') 
  h = require_param(params,'h')
  g = require_param(params,'g')
  w = require_param(params,'w')
  dparmax = optional_param(params,'dparmax',1.0)
  eps = require_param(params,'eps')
  skip = require_param(params,'skip')
  bump = optional_param(params,'bump',0)
  prefer_forward = (optional_param(params,'prefer_forward',1)==1)
  $verbosity = optional_param(params,'verbosity',3)
  if !(params.empty?) then print "unrecognized parameters: #{params.keys}\n"; exit(-1) end
  $brute_force = false
  $debug = false

  xi,yi,zi = spherical_to_cartesian(lati,loni,0.0,lat0,lon0) # we don't use zi

  grid_d = 100.0 # meters; spacing of a square grid used for sorting and searching; value only affects efficiency, not results
  ngrid = point_to_grid([x_hi,y_hi],box,grid_d).max+1 # size of larger dimension of grid

  grid = build_grid(paths,grid_d,box)

  paths.each { |path| estimate_length(path) }
  l = paths[0].last['d']

  if $verbosity>=3 then print "bounding box: x=#{x_lo},#{x_hi}, y=#{y_lo},#{y_hi}, ngrid=#{ngrid}, lati,loni=#{lati},#{loni} xi,yi=#{xi},#{yi} l=#{l}\n" end

  d,true_path = propel(paths,xi,yi,xi,yi,eps,h,g,w,l,dparmax,bump,box,ngrid,grid_d,grid,prefer_forward)
        # true_path = array of points
        # FIXME -- assumes final point is same as initial
  print "total horizontal distance = #{d/1000.0} km\n"

  result['path'] = []
  i = 0
  true_path.each { |p|
    x,y = p
    lat,lon,alt = cartesian_to_spherical(x,y,0.0,lat0,lon0)
    if i%skip==0 then result['path'].push([lat,lon,0.0,x,y,0.0]) end
    i=i+1
  }
  File.open('path.json','w') { |f|
    f.print JSON.generate(result)
  }


  # Write a file in gpsbabel's unicsv format:
  File.open('path.csv','w') { |f|
    f.print "Latitude,Longitude,Altitude\n"
    i = 0
    true_path.each { |p|
      x,y = p
      if i%skip==0 then
        lat,lon,alt = cartesian_to_spherical(x,y,0.0,lat0,lon0)
        f.print "#{lat},#{lon},0.0\n"
      end
      i=i+1
    }
  }


end

def estimate_length(path)
  d = 0.0
  path[0]['d'] = 0.0
  path[0]['i'] = 0
  0.upto(path.length-2) { |n|
    d = d+dist2d(path[n]['p'],path[n+1]['p'])
    path[n+1]['d'] = d
    path[n+1]['i'] = n+1
  }
end

def propel(paths,xi,yi,xf,yf,eps,h,g,window_type,l,dparmax,bump,box,ngrid,grid_d,grid,prefer_forward)
  # l = estimated length of entire path, in meters
  # dparmax = max fractional difference in estimated d (0 to 1)
  p = [xi,yi]
  n = paths.length
  d = 0.0 # integrated horizontal distance
  dpath = Array.new(n, 0.0) # ... for individual paths
  warnings = Array.new(n, {})
  true_path = [p]
  max_par_diff = dparmax*l
  approaching_finish = false
  closest_approach_to_finish = 1.0e10
  i=0
  most_recent_i = Array.new(paths.length, 0)
  print "starting at p=#{p}\n"
  while true
    f = [0.0,0.0]
    terms = [] # terms in the sum used to compute f; used for debugging
    0.upto(paths.length-1) { |m|
      path = paths[m]
      if p[0].nan? || p[1].nan? then print "p is nan in propel\n"; exit(-1) end
      closest = closest_point(p,m,paths,box,ngrid,grid_d,grid,d,max_par_diff,most_recent_i[m],prefer_forward,h*100.0)
      r,q,t,ii,par_diff = closest[0]
              # r,q,t=distance,point,tangent,index
      if false && m==0 && ((d>3135.0 && d<3145.0) || d>7364.0) then # qwe
        #### $brute_force = true
        $debug = true
        dd = dist2d(p,q)
        u = paths[m][ii]
        v = u['succ']
        print "d=#{d} m=#{m} par_diff=#{par_diff} p=#{p} q=#{q} seg=#{u['p']}-#{v['p']} closest dist=#{dd}\n"
      end
      badness = closest[1] # normally 0
      if badness>=2.0  && !(warnings[m].has_key?('badness')) then
        warnings[m]['badness'] = true
        print "track #{m} has badness score of #{badness}, #{r} meters away, at d=#{d}\n"
      end
      if r>1000.0 && !(warnings[m].has_key?('out_of_range')) then
        warnings[m]['out_of_range'] = true
        print "track #{m} is #{r} meters away, which is more than 1 km, at d=#{d}\n"
      end
      if !ii.nil? && ii>most_recent_i[m] then most_recent_i[m]=ii end
      next if r>=h
      u = r/h
      w = window(u,window_type)
      t = normalize2d(t)
      # longitudinal propulsive force
      f_lon = scalar_mul2d(t,w)
      if f_lon[0].nan? || f_lon[1].nan? then print "f_lon is nan in propel\n"; exit(-1) end
      f = add2d(f,f_lon)
      # attractive transverse force
      r = sub2d(q,p)
      rmag = mag2d(r)
      rhat = scalar_mul2d(r,1.0/rmag)
      f_tr = scalar_mul2d(rhat,w*(rmag/g)) # should probably project out any comp. parallel to this segment
      if f_tr[0].nan? || f_tr[1].nan? then f_tr=[0.0,0.0] end # happens if r=0
      f = add2d(f,f_tr)
      terms.push([m,f_lon,f_tr])
    }
    if f[0].nan? || f[1].nan? then print "f is nan in propel\n"; exit(-1) end
    if mag2d(f)==0.0 then
      if bump!=1 then
        print "propel() terminated with f=0 at d=#{d} meters, p=#{p}\n"
        break
      else
        fail,p = do_bump(p,paths,most_recent_i,eps)
        if fail then print "propel terminated, tried to bump past end\n"; break end
        next
      end
    end
    if d>2.0*l then
      print "propel() terminated due to distance greater than twice the estimated length\n"
      break
    end
    if d>max_par_diff && (p[0]-xf).abs<h && (p[1]-yf).abs<h then
      approaching_finish=true
      d_finish = dist2d(p,[xf,yf])
      if d_finish>closest_approach_to_finish then
        print "propel() terminated due to passing the finish point\n"
        break
      end
      closest_approach_to_finish = d_finish
    end
    f = normalize2d(f)
    dp = scalar_mul2d(f,eps)
    if dp[0].nan? || dp[1].nan? then print "dp is nan in propel\n"; exit(-1) end
    d = d+mag2d(dp)
    p = add2d(p,dp)
    true_path.push(p)
    print "d=#{d},    p=#{p},    f=#{f}\n" if i%1000==0 && $verbosity>=3
    if true_path.length>=3 && dist2d(true_path[-1],true_path[-3])<0.000001 then
      # bouncing back and forth between two points, a common behavior
      if bump!=1 then
        print "propel() terminated due to bouncing at d=#{d} meters\n"
        debug_terms(terms)
        break
      else
        fail,p = do_bump(p,paths,most_recent_i,eps)
        if fail then print "propel terminated, tried to bump past end\n"; break end
      end
    end
    i=i+1
  end
  return [d,true_path]
end

# method to get past incorrect stops
# bump each index by 1, and move path to point on 0th path
# (tried moving to average of the points, but the average could then be nowhere near any point)
def do_bump(p,paths,most_recent_i,eps)
  old_p = p
  0.upto(most_recent_i.length-1) { |m| most_recent_i[m] = most_recent_i[m]+1 }
  i = most_recent_i[0]
  if i>paths[0].length-1 then return [true,p] end
  p = paths[0][i]['p']
  p = add2d(p,[0.0001,0.0001]) # without this, we get errors because we're not in general position
  if dist2d(old_p,p)>100.0*eps then
    print "warning in do_bump, hop of #{dist2d(old_p,p)}, #{paths[0][i-1]['p']}, #{paths[0][i]['p']}, bumped to i=#{most_recent_i[0]}\n"
    0.upto(most_recent_i.length-1) { |m|
      print "paths[#{m}][...]=#{paths[m][most_recent_i[m]]['p']}\n"
    }
  end
  return [false,p]
end

def debug_terms(terms)
  f = [0.0,0.0]
  print "terms in f:\n"
  terms.each { |term|
    m,f_lon,f_tr = term
    print "  m=#{m} f_lon=#{f_lon}, f_tr=#{f_tr}\n"
    f = add2d(f,f_lon)
    f = add2d(f,f_tr)
  }
  print "f=#{f}\n"
end

def window(x,window_type)
  # Output is in [0,1].
  # Input is meant to be positive, prescaled distance, with [0,1) giving nonzero results.
  # Neg inputs are OK too.

  if x>=1.0 || x<=-1.0 then return 0 end

  if window_type=='square' then
    return 1.0  
  end
  if window_type=='hann' then
    # 2-dimensional rotation of Hann window
    # Some people do an outer product for 2-dim applications, but I want this to be rotationally invariant.
    return 0.5*(1+Math::cos(x*Math::PI))
  end
end

def require_param(params,name)
  x = params[name]
  if x.nil? then fatal_error("required parameter #{name} is not present") end
  params.delete(name)
  return x
end

def optional_param(params,name,default)
  x = params[name]
  if x.nil? then return default end
  params.delete(name)
  return x
end

# Given a point x, find the nearest point (vertex or interior) on path m.
# Return [[distance,point,tangent],badness].
# This is a high-level routine, which actually calls a different workhorse routine to do the computations.
# This routine's only job is to try to impose the preferences optionally defined by max_par_diff and
# prefer_forward. It looks for solutions that lie closer than the distance defined by grab_if_closer_than,
# and if it finds some of those, it returns the one that comes closest to satisfying the preferences.
# If no points that close are found, it resorts to scoring the solutions on a heuristic scale (badness).
# A normal result has badness=0. A badness of 2 is pretty bad, probably worth warning about.
def closest_point(x,m,paths,box,ngrid,grid_d,grid,d,max_par_diff,not_before_i,prefer_forward,grab_if_closer_than)
  candidates = []
  i_par_diff_lo = (max_par_diff<1.0e10 ? 1 : 2)
  i_force_forward_lo = (prefer_forward ? 1 : 2)
  i_par_diff_lo.upto(2) { |i_par_diff|
    i_force_forward_lo.upto(2) { |i_force_forward|
      badness = 3.0*(i_par_diff-i_par_diff_lo)+1.0*(i_force_forward-i_force_forward_lo)
      force_forward = (i_force_forward==1)
      actual_max_par_diff = (i_par_diff==1 ? max_par_diff : 1.0e10)
      candidate = closest_point_low_level(x,m,paths,box,ngrid,grid_d,grid,d,actual_max_par_diff,not_before_i,force_forward)
      min_d,best_p,best_t,best_i,best_par_diff = candidate
      if min_d<grab_if_closer_than then return [candidate,badness] end # qwe - does this break things?
      badness = badness+Math.log10(min_d/grab_if_closer_than)
              # the log term is guaranteed to be >0
      candidates.push([badness,candidate,i_par_diff,i_force_forward])
    }
  }
  candidates.sort! { |a,b| a[0] <=> b[0] }
  badness = candidates[0][0]
  result = candidates[0][1]

  min_d,best_p,best_t,best_i,best_par_diff = result
  if min_d>1.0e6 then
    print "error, closest_point is #{min_d} meters away, prefer_forward=#{prefer_forward}, max_par_diff=#{max_par_diff}\n"
    candidates.each { |a|
      print "  min_d,best_p,best_t,best_i = #{a[1]}, badness=#{a[0]}, i_par_diff=#{a[2]}, i_force_forward=#{a[3]}\n"
    }
    exit(-1)
  end
  
  return [result,badness]

end

# workhorse routine called by closest_point()
# we call it up to four times for different combinations of max_par_diff and force_forward
def closest_point_low_level(x,m,paths,box,ngrid,grid_d,grid,d,max_par_diff,not_before_i,force_forward)
  if $brute_force then
    return closest_point_low_level_brute_force(x,m,paths,box,ngrid,grid_d,grid,d,max_par_diff,not_before_i,force_forward)
  else
    return closest_point_low_level_indexed(x,m,paths,box,ngrid,grid_d,grid,d,max_par_diff,not_before_i,force_forward)
  end
end

def closest_point_low_level_indexed(x,m,paths,box,ngrid,grid_d,grid,d,max_par_diff,not_before_i,force_forward)
  if x[0].nan? || x[1].nan? then print "x is nan in closest_point\n"; exit(-1) end
  i,j=point_to_grid(x,box,grid_d)
  min_d = 1.0e10
  best_p = nil
  best_t = nil
  best_i = nil
  best_par_diff = nil
  n_tried = 0
  debug = $debug && m==0 # qwe
  if debug then print "--- x=#{x}, i=#{i}, j=#{j} max_par_diff=#{max_par_diff}\n" end
  0.upto(ngrid-1) { |r|
    # trace a 2r x 2r square around grid square i,j
    (-r).upto(r) { |u|
      best = (r-1.0)*grid_d # closest we could get from now on
      if debug && best>min_d*1.414 then print "      --- returning, min_d=#{min_d}, best_par_diff=#{best_par_diff} \n" end
      return [min_d,best_p,best_t,best_i,best_par_diff] if best>min_d*1.414 # This is the normal exit, but there is another below.
      0.upto(3) { |edge| # top, bottom, right, left
        ii = i
        jj = j
        if edge==0 then jj=jj+r; ii=ii+u end
        if edge==1 then jj=jj-r; ii=ii+u end
        if edge==2 then ii=ii+r; jj=jj+u end
        if edge==3 then ii=ii-r; jj=jj+u end
        next if grid[[ii,jj]].nil?
        grid[[ii,jj]].each { |seg|
          mm,v = seg # path mm's segment from vertex v to its successor may cross (ii,jj)
          next if mm!=m
          par_diff = (v['d']-d).abs
          next if par_diff>max_par_diff
          n_tried = n_tried+1
          next if force_forward && v['i']<not_before_i
          dd,p,t = closest_point_on_segment(x,v['p'],v['succ']['p'])
          if dd<min_d then
            min_d=dd
            best_p = p
            best_t = t
            best_i = v['i']
            best_par_diff = par_diff
          end
        }
      }
    }
  }
  if min_d>1.0e8 && max_par_diff>1.0e6 && !force_forward then
    print "something is wrong in closest_point_low_level, min_d=#{min_d}, max_par_diff=#{max_par_diff}, force_forward=#{force_forward}\n"
    print "  n_tried=#{n_tried}, d=#{d}\n"
    exit(-1)
  end
  return [min_d,best_p,best_t,best_i,best_par_diff] # This is not the normal way we exit.
end

def closest_point_low_level_brute_force(x,m,paths,box,ngrid,grid_d,grid,d,max_par_diff,not_before_i,force_forward)
  i,j=point_to_grid(x,box,grid_d)
  min_d = 1.0e10
  best_p = nil
  best_t = nil
  best_i = nil
  best_par_diff = nil
  0.upto(paths.length-1) { |m|
    path = paths[m]
    0.upto(path.length-2) { |n|
      path[n]['succ'] = path[n+1]
      v = path[n]
      p = path[n]['p']
      q = path[n+1]['p']
      par_diff = (v['d']-d).abs
      dd,p,t = closest_point_on_segment(x,v['p'],v['succ']['p'])
      if dd<min_d then
        min_d=dd
        best_p = p
        best_t = t
        best_i = v['i']
        best_par_diff = par_diff
      end
    }
  }
  return [min_d,best_p,best_t,best_i,best_par_diff] # This is not the normal way we exit.
end

# Given a point x and a segment pq, find the point on segment pq closest to x.
# Return [distance,point,tangent].
def closest_point_on_segment(x,p,q)
  a = sub2d(q,p)
  t = dot2d(a,sub2d(x,p))/dot2d(a,a)
  if t<=0.0 then
    e=p
  else
    if t>=1.0 then
      e=q
    else
      e=add2d(p,scalar_mul2d(a,t))
    end
  end
  return [mag2d(sub2d(e,x)),e,a]
end

def build_grid(paths,grid_d,box)
  # data structures used for searching and sorting
  # also adds some stuff to paths
  grid = {}
      # if i,j are grid indices, then grid[[i,j]] is either nil or a list
      # of the form [[m,v],[m2,v2],...], meaning that path m's segment from vertex v to its successor may cross (i,j)
  0.upto(paths.length-1) { |m|
    path = paths[m]
    0.upto(path.length-2) { |n|
      path[n]['succ'] = path[n+1]
      p = path[n]['p']
      q = path[n+1]['p']
      i,j = point_to_grid(p,box,grid_d)
      ii,jj = point_to_grid(q,box,grid_d)
      i_lo = [i,ii].min
      i_hi = [i,ii].max
      j_lo = [j,jj].min
      j_hi = [j,jj].max
      path[n]['grid_box'] = [i_lo,i_hi,j_lo,j_hi]
      i_lo.upto(i_hi) { |i|
        j_lo.upto(j_hi) { |j|
          if !(grid.has_key?([i,j])) then grid[[i,j]]=[] end
          grid[[i,j]].push([m,path[n]])
        }
      }
    }
  }
  return grid
end

def point_to_grid(p,box,grid_d)
  x,y = p
  x_lo,x_hi,y_lo,y_hi = box
  begin
    result = [((x-x_lo)/grid_d).floor,((y-y_lo)/grid_d).floor]
  rescue => exception
    print "error in point_to_grid, x=#{x}, x_lo=#{x_lo}, grid_d=#{grid_d}, y=#{y}, y_lo=#{y_lo}\n"
    print exception.backtrace
    exit(-1)
  end
  return result
end

def get_bounding_box(paths)
  x_lo = 1.0e20
  x_hi = -1.0e20
  y_lo = 1.0e20
  y_hi = -1.0e20
  paths.each { |path|
    path.each { |v|
      x,y = v['p']
      x_lo=x if x < x_lo
      x_hi=x if x > x_hi
      y_lo=y if y < y_lo
      y_hi=y if y > y_hi
    }
  }
  return [x_lo,x_hi,y_lo,y_hi]
end

def import_csv(file)
  # csv file looks like:
  # lat,lon,alt,x,y,z
  # 34.266225,-117.626925,1884.1385896780353,0.00,0.00,0.00

  a = CSV.open(file, 'r', :headers => true).to_a.map { |row| row.to_hash }
  #          ... http://technicalpickles.com/posts/parsing-csv-with-ruby/

  # output array of hashes now looks like (represented as JSON):
  #   [{"p":[0.00,0.00]},...]

  path = []
  a.each { |h|
    alt = 0.0
    path.push({'p'=>[h['x'].to_f,h['y'].to_f]})
  }
  return path
end

def require_equal(x,y)
  if (x-y).abs>1e-10 then fatal_error("failing, #{x}!=#{y}!") end
end

def tests
end

def fatal_error(message)
  $stderr.print "crossings.rb: fatal error: #{message}\n"
  exit(-1)
end

if false then
  tests
  $stderr.print "done testing\n"
  exit(0)
end

main
