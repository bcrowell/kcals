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

def add2d(p,q)
  return [p[0]+q[0],p[1]+q[1]]
end

def sub2d(p,q)
  return [p[0]-q[0],p[1]-q[1]]
end

def dot2d(p,q)
  return p[0]*q[0]+p[1]*q[1]
end

def scalar_mul2d(p,s)
  return [s*p[0],s*p[1]]
end

def normalize2d(p)
  return scalar_mul2d(p,1.0/mag2d(p))
end

def dist2d(p,q)
  return mag2d(sub2d(p,q))
end

def mag2d(p)
  return Math::sqrt(dot2d(p,p))
end
