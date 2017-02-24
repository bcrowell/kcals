def earth_radius(lat)
  # https://en.wikipedia.org/wiki/Earth_radius#Geocentric_radius
  a = 6378137.0 # earth's equatorial radius, in meters
  b = 6356752.3 # polar radius
  slat = Math::sin(deg_to_rad(lat))
  clat = Math::cos(deg_to_rad(lat))
  return Math::sqrt( ((a*a*clat)**2+(b*b*slat)**2) / ((a*clat)**2+(b*slat)**2)) # radius in meters
end

def cartesian_to_spherical(x,yy,z,lat0,lon0)
  # returns [lat,lon,altitude], in units of degrees, degrees, and meters
  # see spherical_to_cartesian() for description of coordinate systems used and the transformations.
  # Calculate a first-order approximation to the inverse of the polyconic projection:
  r0 = earth_radius(lat0)
  zz = z+r0
  slat0 = Math::sin(deg_to_rad(lat0))
  clat0 = Math::cos(deg_to_rad(lat0))
  r = Math::sqrt(x*x+yy*yy+zz*zz)
  y =  clat0*yy+slat0*zz
  zzz = -slat0*yy+clat0*zz
  lat = rad_to_deg(Math::asin(y/r))
  lon = rad_to_deg(Math::atan2(x,zzz))+lon0
  1.upto(10) { |i| # more iterations to improve the result
    x2,y2,z2 = spherical_to_cartesian(lat,lon,z,lat0,lon0)
    dx = x-x2
    dy = yy-y2
    break if dx.abs<1.0e-8 and dy.abs<1.0e-8
    lat = lat + rad_to_deg(dy/r0)
    lon = lon + rad_to_deg(dx/(r0*clat0)) if clat0!=0.0
  }
  return [lat,lon,z]
end

def spherical_to_cartesian(lat,lon,alt,lat0,lon0)
  # Inputs are in degrees, except for alt, which is in meters.
  # The "cartesian" coordinates are not actually cartesian. They're coordinates in which
  # (x,y) are from a polyconic projection https://en.wikipedia.org/wiki/Polyconic_projection
  # centered on (lat0,lon0), and z is altitude.
  # (In older versions of the software, z was distance from center of earth.)
  # Outputs are in meters. The metric for the projection is not exactly euclidean, so later
  # calculations that treat these as cartesian coordinates are making an approximation. The error
  # should be tiny on the scales we normally deal with. The important thing for our purposes is
  # that the gradient of z is vertical.
  # The purpose of lat0 and lon0 is to do a rotation to make the cartesian coordinates easier to interpret.
  # outputs are in meters. We rotate to coordinate axes parallel to NSEWUD at initial point.
  # The notation in the following is the notation from the WP article.
  lam = deg_to_rad(lon)
  lam0 = deg_to_rad(lon0)
  phi = deg_to_rad(lat)
  phi0 = deg_to_rad(lat0)
  cotphi = 1/Math::tan(phi)
  u = (lam-lam0)*Math::sin(phi) # is typically on the order of 10^-3 (half the width of a USGS topo)
  if u.abs<0.01
    # use taylor series to avoid excessive rounding in calculation of 1-cos(u)
    u2 = u*u
    u4 = u2*u2
    one_minus_cosu = 0.5*u2-(0.0416666666666667)*u4+(1.38888888888889e-3)*u2*u4-(2.48015873015873e-5)*u4*u4
      # max error is about 10^-27, which is a relative error of about 10^-23
  else
    one_minus_cosu = 1-Math::cos(u)
  end
  r0 = earth_radius(lat0)
        # Use initial latitude and keep r0 constant. If we let r0 vary, then we also need to figure
        # out the direction of the g vector in this model.
  x = r0*cotphi*Math::sin(u)
  y = r0*((phi-phi0)+cotphi*one_minus_cosu)
  z = alt
  return [x,y,z]
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
