#!/usr/bin/ruby

require 'json'
require 'csv' # standard ruby library

$lib = "../lib"

require_relative "#{$lib}/geometry"
require_relative "#{$lib}/low_level_math"
require_relative "#{$lib}/system"

# usage:
#   ./propel.rb '{"lati":34.26645,"loni":-117.62755,"h":10.0,"dparmax":0.25,"eps":3.0,"skip":10}' baldy/preprocessed/baldy_0*.json
# First arg is parameters, formatted as a JSON hash.
# The rest are files giving polygonal approximations to gps tracks. They should
# contain columns x and y -- maybe z? Can contain other columns.
# Writes path.json and path.csv.
# parameters:
#   lati,loni -- initial lat and lon, in degrees
#   h -- in meters, sets the width of the window for averaging of paths
#   dparmax -- unitless; ignore points on a path that differ in estimated parameter by more than this fractional amount
#   eps -- distance to move in meters at each step
#   skip -- e.g., if this is 10, then only write every 10th point to the output files

$verbosity = 3

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
  dparmax = require_param(params,'dparmax')
  eps = require_param(params,'eps')
  skip = require_param(params,'skip')
  xi,yi,zi = spherical_to_cartesian(lati,loni,0.0,lat0,lon0) # we don't use zi

  grid_d = 100.0 # meters; spacing of a square grid used for sorting and searching; value only affects efficiency, not results
  ngrid = point_to_grid([x_hi,y_hi],box,grid_d).max+1 # size of larger dimension of grid

  grid = build_grid(paths,grid_d,box)

  paths.each { |path| estimate_length(path) }
  l = paths[0].last['d']

  if $verbosity>=3 then print "bounding box: x=#{x_lo},#{x_hi}, y=#{y_lo},#{y_hi}, ngrid=#{ngrid}, lati,loni=#{lati},#{loni} xi,yi=#{xi},#{yi} l=#{l}\n" end

  d,true_path = propel(paths,xi,yi,xi,yi,eps,h,l,dparmax,box,ngrid,grid_d,grid)
        # true_path = array of points
        # FIXME -- assumes final point is same as initial
  print "total horizontal distance = #{d/1000.0} km\n"

  result['path'] = []
  i = 0
  true_path.each { |p|
    x,y = p
    lat,lon,alt = cartesian_to_spherical(x,y,0.0,lat0,lon0)
    if i%10==skip then result['path'].push([lat,lon,0.0,x,y,0.0]) end
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
  0.upto(path.length-2) { |n|
    d = d+dist2d(path[n]['p'],path[n+1]['p'])
    path[n+1]['d'] = d
  }
end

def propel(paths,xi,yi,xf,yf,eps,h,l,dparmax,box,ngrid,grid_d,grid)
  # l = estimated length of entire path
  p = [xi,yi]
  n = paths.length
  d = 0.0 # integrated horizontal distance
  dpath = Array.new(n, 0.0) # ... for individual paths
  true_path = [p]
  max_par_diff = dparmax*l
  approaching_finish = false
  closest_approach_to_finish = 1.0e10
  i=0
  while true
    f = [0.0,0.0]
    0.upto(paths.length-1) { |m|
      path = paths[m]
      r,q,t = closest_point(p,m,paths,box,ngrid,grid_d,grid,d,max_par_diff) # r,q,t=distance,point,tangent
      # print "r,q,t=#{r},    #{q},    #{t}\n"
      next if r>=h
      u = r/h
      w = window(u)
      t = normalize2d(t)
      # longitudinal propulsive force
      f = add2d(f,scalar_mul2d(t,w))
      # attractive transverse force
      rhat = normalize2d(sub2d(q,p))
      f = add2d(f,scalar_mul2d(rhat,w*u))
    }
    if mag2d(f)==0.0 then
      print "propel() terminated with f=0 at d=#{d} meters\n"
      break
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
    d = d+mag2d(dp)
    p = add2d(p,dp)
    true_path.push(p)
    print "d=#{d},    p=#{p},    f=#{f}\n" if i%1000==0
    i=i+1
  end
  return [d,true_path]
end

def window(x)
  # 2-dimensional rotation of Hann window
  # Output is in [0,1].
  # Input is meant to be positive, prescaled distance, with [0,1) giving nonzero results.
  # Neg imputs are OK too.
  # Some people do an outer product for 2-dim applications, but I want this to be rotationally invariant.
  if x>=1.0 || x<=-1.0 then return 0 end
  return 0.5*(1+Math::cos(x/Math::PI))
end

def require_param(params,name)
  x = params[name]
  if x.nil? then fatal_error("required parameter #{name} is not present") end
  return x
end

# Given a point x, find the nearest point (vertex or interior) on path m.
# Return [distance,point,tangent].
def closest_point(x,m,paths,box,ngrid,grid_d,grid,d,max_par_diff)
  i,j=point_to_grid(x,box,grid_d)
  min_d = 1.0e10
  best_p = nil
  best_t = nil
  0.upto(ngrid-1) { |r|
    # trace a 2r x 2r square around grid square i,j
    -r.upto(r) { |u|
      best = (r-1.0)*grid_d # closest we could get from now on
      return [min_d,best_p,best_t] if best>min_d*1.414
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
          next if (v['d']-d).abs>max_par_diff
          dd,p,t = closest_point_on_segment(x,v['p'],v['succ']['p'])
          if dd<min_d then
            min_d=dd
            best_p = p
            best_t = t
          end
        }
      }
    }
  }
  return [min_d,best_p,best_t] # This is not the normal way we exit.
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
  return [((x-x_lo)/grid_d).floor,((y-y_lo)/grid_d).floor]
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
