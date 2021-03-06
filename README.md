kcals
=====

This software estimates your energy expenditure from running or walking,
based on a GPS track or a track generated by an application such as
google maps or mapmyrun. 

To download a track from mapmyrun: Pop up the route in your browser.
On the right-hand side of the screen, under ROUTE INFO, do Export this
Route. In the pop-up, click on the tab that says EXPORT AS KML, then
do DOWNLOAD KML FILE. 

The model used to calculate the results is described in this paper:

B. Crowell, "From treadmill to trails: predicting performance of runners,"
https://www.biorxiv.org/content/10.1101/2021.04.03.438339v1 , doi: 10.1101/2021.04.03.438339 

The output from this software is most useful if you want to compare
one run to another, e.g., if I want to know how a mountain run with lots of elevation gain
compares with a flat run at a longer distance, or if I want to project whether doing a certain
trail as a run is feasible for me.

## Use through the web interface

The web interface is available [here](http://www.lightandmatter.com/kcals)

## Use from the command line

synopsis:

`kcals.rb route.kml`

`kcals.rb filtering=600 weight=58 route.kml`

Total stats are written to standard output.

Also writes some spreadsheet data to profile.csv and path.csv.
The profile.csv file can be used to graph the elevation profile. 

## Input files

There is a wide variety of formats used by GPS units and applications such as Google Earth and MapMyRun.

Formats accepted are:

kml - the default

gpx

txt - the text format written by gpsvisualizer.com

csv - the unicsv format written by gpsbabel (or any CSV file with some of its columns labeled
Latitude, Longitude, and possibly Altitude)

If your data are not in one of these formats, you can convert them using gpsbabel, either on your
own machine or on the web service at gpsvisualizer.com/gpsbabel.

This kind of file can generally contain waypoints (named points of interest), a track (a list of points, often
from GPS measurements), or a route (a list of waypoints, which are usually goals, not actual spots you
visited). The data for input to this software must be in a track (not a route).
If you want to use a file that consists only of waypoints, use gpsbabel to convert it to
CSV format like this:

`gpsbabel -w -i kml -f foo.kml -o unicsv -F foo.csv`

However, this may give very inaccurate results if the real route is not well approximated by
straight line segments connecting the waypoints.

## Parameters and preferences

Preferences are read from the file ~/.kcals, but can be overridden from the command line.
See the file sample_prefs for a sample preferences file.

Parameters are:

  metric -- 0 for US units, 1 for metric

  running -- 0 for walking, 1 for running

  weight -- body mass in kg

  filtering -- see below

  xy_filtering -- see below

  format -- see above for supported formats

  verbosity -- a level from 0 to 3

  dem -- 1 means try to download elevation data if it's not included in the input, 0 means don't

  nominal_h -- the nominal distance of the run, in miles if metric=0, km if metric=1; see below

  split_energy_at -- at this distance, print out the energy used so far; distance is in miles if metric=0, km if metric=1; for use in predicting split times (see below)

  rec -- set to 0 to use the cost of running directly from treadmill studies, 1 to use a modified "recreational" version that is usually more realistic; default is 1

## Filtering

The parameters filtering and xy_filtering both represent horizontal distances
in units of meters. Their defaults values are 200 and 30, respectively. These are meant to get rid of bogus
oscillations in the data. Any elevation (z) changes that occur over horizontal distances less
than the value of "filtering" will tend to get filtered out, and likewise any horizontal motion that occurs
over horizontal distances less than the value of "xy_filtering."
To turn off filtering, set the relevant parameter to 0. 

The choice of the vertical filtering parameter
can have a huge effect on the total elevation gain, but the
effect on the calorie expenditure is usually fairly small.
There are several reasons why it may be a good idea to set a fairly large value of the vertical
("filtering") parameter:

 1. If the resolution of the horizontal track is poor, then it may appear to go up and down steep hillsides,
          when in fact the real road or trail contours around them.

 2. If elevations from GPS are being used (which is a bad idea), then random fluctuations in the GPS
          elevations can cause large errors.

 3. If the elevations are being taken from a digital elevation model (DEM), which is generally a good
         idea, then there may still be certain types of errors.
         Trails and roads are intentionally constructed so as not to go up and down steep hills, but
         the DEM may not accurately reflect this. The most common situation seems to be one in which
         a trail or road takes a detour into a narrow gully in order to maintain a steady grade.
         The DEM currently used by this software has a horizontal resolution of 30 meters.
         If the gully is narrower than this, then the DEM doesn't know about the the gully, and
         the detour appears to be a steep excursion up and then back down the prevailing slope.
         I have found empirically that setting filtering=60 m is roughly the minimum that is required
         in order to eliminate this type of artifact, which makes sense because a detour into a 30 meter
         gully probably does involve about 60 meters of horizontal travel.

My rules of thumb for setting the filtering are as follows:

 * For most runs with relatively short and not insanely steep hills, the default vertical filtering
     parameter of 60 m works well. Using a higher filtering value leads to wrong results, because
     the hills get smoothed out entirely.

 * For very steep runs with a lot of elevation gain, in rugged terrain, it's necessary to use a
     larger filtering value of about 200 m. Otherwise the energy estimates are much too high.
     This is the software's default.

The mileage derived from a GPS track can vary quite a bit depending on the resolution of the GPS data.
Higher resolution increases the mileage, because small wiggles get counted in. This has a big effect on
the energy calculation, because the energy is mostly sensitive to mileage, not gain.

## Adding elevation data

Many applications, such as mapmyrun, output tracks in KML format but set all the altitude data to
zero. To get around this, there are two options:

(1) Run the KML file through the filter at
http://www.gpsvisualizer.com/elevation . Under "output," select
"plain text." Run this software with format=text.

(2) Set dem=1, and if the software detects that elevation information is missing from the input
file, it will download it.

## Nominal distances

The nominal_h parameter allows you to force the distance to equal some set value. For example,
the Chino Hills Half Marathon is supposed to be the standard half-marathon distance of 13.1 miles.
I clicked on a satellite image in mapmyrun.com to make a polygonal approximation to the course,
saved it in a KML file, and analyzed it using kcals.
The distance came out to be 12.4 mi, which is a little short, presumably because I was somewhat
sloppy about making the polygon's resolution fine enough to accurately match the course.
By setting nominal_h=13.1 (with metric=0, so that the units are miles), I can roughly get rid
of this inaccuracy by scaling up all the horizontal distances by the appropriate factor.

This scaling factor strongly affects the estimate of energy consumption, which depends mainly
on the total horizontal distance. In the example above, there will also be a slight additional
decrease in energy consumption because all of the slopes go down a little. The scaling factor
is taken into account in the output file profile.csv, but not in path.csv.

## Estimating split times

For example, suppose that the run is 6.40 miles, and you want to predict your split time at 4.67 miles.
Then you would do something like this:

`kcals.rb dem=1 split_energy_at=4.67 my_run.gpx`

If this tells you that the energy used up to this point is a value equal to 77% of the total (slightly
more than would have been predicted based purely on mileage), then you can estimate that your split
time will be .77 of your total time.

## Installing

### Minimal installation

apt-get install gpsbabel

### To allow downloading of elevation data:

apt-get install libgdal-dev gdal-bin python-gdal python-pip

pip install setuptools && pip install elevation

eio selfcheck

When first installing the software, it seems possible to get the elevation tools into a
state where they give mysterious error messages, or where incorrect (zero) elevation data
gets returned. In the latter situation, do an "eio clean." In the former situation,
try to debug by doing a command that is supposed to work according to the documentation:

eio clip -o Rome-30m-DEM.tif --bounds 12.35 41.8 12.65 42

### CGI

Edit the URL used in kcals.html to refer to kcals.cgi.

sudo make cgi
