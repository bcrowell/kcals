kcals
=====

This software estimates your energy expenditure from running or walking,
based on a GPS track or a track generated by an application such as
google maps or mapmyrun. 

To download a track from mapmyrun: Pop up the route in your browser.
On the right-hand side of the screen, under ROUTE INFO, do Export this
Route. In the pop-up, click on the tab that says EXPORT AS KML, then
do DOWNLOAD KML FILE. 

The calorie expenditure is calculated from Minetti et al., http://jap.physiology.org/content/93/3/1039.full .
They got their data from elite mountain runners (all male) running on a treadmill.
The outputs seem low compared to other estimates I've seen. This may be because these
elite athletes were very efficient, were not carrying packs or wearing heavy boots, and
were running on a nice uniform treadmill. I find the data most useful if I want to compare
one run to another, e.g., if I want to know how a mountain run with lots of elevation gain
compares with a flat run at a longer distance.

## Use through the web interface

The web interface is available [here](http://www.lightandmatter.com/kcals)

## Use from the command line

synopsis:

`kcals.rb <route.kml` ... read parameters from preferences file

`kcals.rb format=txt filtering=600 weight=58 <route.txt` ... override parameters from command line

`kcals.rb filtering=600 weight=58 route.txt` ... final parameter interpreted as input file, format inferred

The input formats that are supported are KML and the text format
written by gpsvisualizer.com.  Total stats are written to standard output.

Also writes some spreadsheet data to profile.csv and path.csv.
The profile.csv file can be used to graph the elevation profile. 

## Input files

There is a wide variety of formats used by GPS units and applications such as Google Earth and MapMyRun.

Formats accepted are:

kml - the default

gpx

text - the text format written by gpsvisualizer.com

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

Preferences are read from the file ~/.kcals, but can be overridden from the command line
See the file sample_prefs for a sample preferences file.

Parameters are:

  metric -- 0 for US units, 1 for metric

  running -- 0 for walking, 1 for running

  weight -- body mass in kg

  filtering -- see below

  format -- see above for supported formats

  verbosity -- a level from 0 to 3

  dem -- 1 means try to download elevation data if it's not included in the input, 0 means don't

## Filtering

Filtering is a parameter with units of meters that defaults to 500, meant to get rid of bogus
oscillations in the height data, which are often present both
in GPS tracks and in elevation profiles derived from digital elevation model (DEM) databases such as SRTM.
To turn off this filtering, set filtering=0.

When using DEM data without filtering, I have found 
noticeable unrealistic wiggles when I graph
the elevation profile using the CSV output file, and the total gain was wildly wrong. However, the
effect on the calorie expenditure output is actually fairly small.

With GPS tracks, filtering seems to greatly improve precision. For instance, I downloaded three different tracks
that people had posted online for a popular mountain loop in LA (Mount Baldy via Devil's Backbone, descending
via the Ski Hut trail). Without filtering, the total gain was estimated to be 5340, 4434, and 4716 feet
based on the three different tracks. With filtering, the estimates were in much better agreement:
3792, 3853, and 3849 feet.

The mileage derived from a GPS track can vary quite a bit depending on the resolution of the GPS data.


## Adding elevation data

Many applications, such as mapmyrun, output GPS tracks in KML format but set all the altitude data to
zero. To get around this, there are two options:

(1) Run the KML file through the filter at
http://www.gpsvisualizer.com/elevation . Under "output," select
"plain text." Run this software with format=text.

(2) Set dem=1, and if the software detects that elevation information is missing from the input
file, it will download it.

## Installing

### Minimal installation

apt-get install libjson-ruby gpsbabel

### To allow downloading of elevation data:

apt-get install libgdal-dev gdal-bin python-gdal python-pip

pip install elevation

### CGI

sudo make cgi
