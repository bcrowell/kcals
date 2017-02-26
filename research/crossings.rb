#!/usr/bin/ruby

require 'json'
require 'csv' # standard ruby library

$lib = "../lib"

require_relative "#{$lib}/geometry"
require_relative "#{$lib}/low_level_math"
require_relative "#{$lib}/system"

# usage:
#   ./crossings.rb '{"outlier_dist":100.0}' baldy/preprocessed/baldy_0*.json
# First arg is parameters, formatted as a JSON hash.
# The rest are files giving polygonal approximations to gps tracks. They should
# contain columns x and y -- maybe z? Can contain other columns.
# params
#   outlier_dist = distance in meters; any point farther than this from nearest neighbor on another path is thrown out

$verbosity = 3

$require_elevations = true

def main
  params = JSON.parse(ARGV.shift)
  input_files = ARGV
 
  paths = []
  rejected = 0
  input_files.each { |file|
    contains_elevations,path = import_json(file)
    # I added elevations to 001 in preprocessing, so the test doesn't actually work.
    if (contains_elevations && !(file=~/001/)) || !$require_elevations then
      paths.push(path)
    else
      rejected = rejected+1
    end
  }
  print "#{paths.length} tracks read from input files\n"
  if $require_elevations then print "  ...#{rejected} rejected for lacking elevations\n" end

  box = get_bounding_box(paths)
  x_lo,x_hi,y_lo,y_hi = box


  grid_d = 100.0 # meters; spacing of a square grid used for sorting and searching; value only affects efficiency, not results
  ngrid = point_to_grid([x_hi,y_hi],box,grid_d).max+1 # size of larger dimension of grid
  if $verbosity>=3 then print "bounding box: x=#{x_lo},#{x_hi}, y=#{y_lo},#{y_hi}, ngrid=#{ngrid}\n" end

  grid = build_grid(paths,grid_d,box)
  paths = remove_outliers(paths,params['outlier_dist'],box,ngrid,grid_d,grid)
  grid = build_grid(paths,grid_d,box) # redo without the bogus points
  # note that it's possible that there will now be points we would consider outliers because their friends are gone

  result = find_crossings(paths,grid,box,ngrid,grid_d)

  if $verbosity>=3 then print "#{result.length} crossings found\n" end
end

def find_crossings(paths,grid,box,ngrid,grid_d)
  result = []
  0.upto(paths.length-2) { |m|
    path = paths[m]
    0.upto(path.length-2) { |n|
      p = path[n]['p']
      q = path[n+1]['p']
      pq = dist2d(p,q)
      i_lo,i_hi,j_lo,j_hi = path[n]['grid_box']
      i_lo.upto(i_hi) { |i|
        j_lo.upto(j_hi) { |j|
          next if grid[[i,j]].nil?
          grid[[i,j]].each { |seg|
            m2,v = seg # path m2's segment from vertex v to its successor may cross (i,j)
            next unless m2>m
            r = v['p']
            s = v['succ']['p']
            rs = dist2d(r,s)
            closest = [dist2d(p,r),dist2d(p,s),dist2d(q,r),dist2d(q,s)].min
            next if closest>pq+rs
            # look for intersection of pq with rs
            x,mu,lambda = intersection_of_segments(p,q,r,s,true)
            next if x.nil?
            tangent = normalize2d(add2d(normalize2d(sub2d(q,p)),normalize2d(sub2d(s,r))))
            print "crossing between paths #{m} and #{m2}, x=#{x}\n" if $verbosity>=4
            result.push({'p'=>x,'mu'=>mu,'lambda'=>lambda,'t'=>tangent})
          }
        }
      }
    }
  }
  return result
end

def remove_outliers(paths,outlier_dist,box,ngrid,grid_d,grid)
  paths2 = []
  0.upto(paths.length-1) { |m|
    paths2[m] = []
    path = paths[m]
    0.upto(path.length-1) { |n|
      p = path[n]['p']
      d = closest_point(p,paths,m,box,ngrid,outlier_dist,grid_d,grid)
      if d>outlier_dist then
        if $verbosity>=4 then $stderr.print "throwing away outlier, path=#{m}, vertex=#{n}, p=#{p}, d=#{d}\n" end
      else
        paths2[m].push(path[n])
      end
    }
  }
  return paths2
end

# return the distance from x to the nearest point (vertex or interior) on any other path
# if we find a distance less than close_enough, return it and stop searching
def closest_point(x,paths,myself,box,ngrid,close_enough,grid_d,grid)
  i,j=point_to_grid(x,box,grid_d)
  min_d = 1.0e10
  0.upto(ngrid-1) { |r|
    # trace a 2r x 2r square around grid square i,j
    -r.upto(r) { |u|
      best = (r-1.0)*grid_d # closest we could get from now on
      return min_d if best>min_d*1.414
      0.upto(3) { |edge| # top, bottom, right, left
        ii = i
        jj = j
        if edge==0 then jj=jj+r; ii=ii+u end
        if edge==1 then jj=jj-r; ii=ii+u end
        if edge==2 then ii=ii+r; jj=jj+u end
        if edge==3 then ii=ii-r; jj=jj+u end
        next if grid[[ii,jj]].nil?
        grid[[ii,jj]].each { |seg|
          m,v = seg # path m's segment from vertex v to its successor may cross (ii,jj)
          next if m==myself
          p = v['p']
          q = v['succ']['p']
          dd = closest_point_on_segment(x,p,q)
          if dd<min_d then
            min_d=dd
            return min_d if min_d<close_enough
          end
        }
      }
    }
  }
end

# find distance from x to closest point on segment pq
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
  return mag2d(sub2d(e,x))
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

def import_json(file)
  data = JSON.parse(slurp_file(file))
  # {"box":[34.266225,34.289151,-117.647213,-117.608728,0.0,0.0],"r":6371396.587202083,
  #  "lat0":34.266225,"lon0":-117.626925,
  #   "path":[[34.266225,-117.626925,1884.1385896780353,0.0,0.0,1884.14],...]}
  path = []
  contains_elevations = false
  data['path'].each { |p|
    alt = 0.0
    x,y,z = [p[3],p[4],p[5]]
    contains_elevations = contains_elevations || z!=0.0
    path.push({'p'=>[x,y,z]})
  }
  return [contains_elevations,path]
end

def intersection_of_segments(p,q,r,s,more_info=false)
  a = sub2d(q,p)
  b = sub2d(s,r)
  mat = invert_2_by_2(b[0],-a[0],b[1],-a[1])
  return nil if mat.nil? # parallel segments; actually pq and rs could lie on same line, but this has probability zero
  q1,q2,q3,q4 = mat
  w = sub2d(p,r)
  mu,lambda = [q1*w[0]+q2*w[1],q3*w[0]+q4*w[1]] # intersection is at p+lambda*a=r+mu*b
  return nil if mu<0 or mu>1 or lambda<0 or lambda>1
  x = add2d(p,scalar_mul2d(a,lambda))
  if more_info then return [x,mu,lambda] else return x end
end

def invert_2_by_2(a,b,c,d)
  det = a*d-b*c
  if det==0.0 then return nil end
  return [d/det,-b/det,-c/det,a/det]
end

def require_equal(x,y)
  if (x-y).abs>1e-10 then fatal_error("failing, #{x}!=#{y}!") end
end

def tests
  require_equal(1.0,closest_point_on_segment([0.0,0.0],[-2.0,1.0],[2.0,1.0]))
  require_equal(Math::sqrt(2.0),closest_point_on_segment([3.0,0.0],[-2.0,1.0],[2.0,1.0]))
  require_equal(Math::sqrt(2.0),closest_point_on_segment([-3.0,0.0],[-2.0,1.0],[2.0,1.0]))
  x = intersection_of_segments([-0.01,0.0],[1.0,0.0],[0.0,-0.01],[0.0,1.0])
  fatal_error("intersection_of_segments is bad") if x.nil? or mag2d(x)>1.0e-10
  x = intersection_of_segments([0.01,0.0],[1.0,0.0],[0.0,0.01],[0.0,1.0])
  fatal_error("intersection_of_segments is bad") unless x.nil?
  x = intersection_of_segments([0.0,0.0],[1.0,0.0],[0.0,1.0],[1.0,1.0]) # parallel
  fatal_error("intersection_of_segments is bad") unless x.nil?
  x = intersection_of_segments([0.0,0.0],[1.0,0.01],[0.0,1.0],[1.0,1.0]) # nearly parallel
  fatal_error("intersection_of_segments is bad") unless x.nil?
  x = intersection_of_segments([0.0,0.0],[1.0,0.0],[0.0,-1.0],[1.0,1.0])
  fatal_error("intersection_of_segments is bad, nil?") if x.nil? 
  fatal_error("intersection_of_segments is bad, wrong, x=#{x}") if (x[0]-0.5).abs>1.0e-10 or x[1].abs>1.0e-10
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
