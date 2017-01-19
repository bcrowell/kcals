kcals
=====

This is Unix command line software that tries to estimate your energy expenditure from
running or walking. 

Many applications, such as mapmyrun, output GPS tracks in KML format but set all the altitude data to
zero. To get around this, run the KML file through the filter at
http://www.gpsvisualizer.com/elevation . Under "output," select
"plain text," and use the option format=text.

usage:

   kcals.rb <route.kml ... read parameters from preferences file

   kcals.rb filtering=600 weight=58 <route.kml ... override parameters from command line

The input formats that are supported are KML and the text format
written by gpsvisualizer.com.  Writes total stats to stdout. Also
writes some spreadsheet data to kcals.csv, which can be used to graph
the elevation profile. 

Preferences are read from the file ~/.kcals, but can be overridden from the command line
See the file sample_prefs for a sample preferences file.

Parameters are:

  metric -- 0 for US units, 1 for metric

  running -- 0 for walking, 1 for running

  weight -- body mass in kg

  filtering -- see below

  format -- text or kml

Filtering is a parameter with units of meters that defaults to 500, meant to get rid of bogus
oscillations in the height data, which seem to be present in the databases used by
gpsvisualizer.com. To turn off this filtering, set filtering=0.
Without filtering, you will get noticeable unrealistic wiggles when you graph
the elevation profile using the CSV output file, and the total gain will be wildly wrong. However, the
effect on the calorie expenditure output is actually fairly small.
If these effects matter to you, and you want maximum precision, then
I recommend adjusting the value of the filtering parameter in order to reproduce a reliable
figure for the total gain, e.g., the one output by mapmyrun.

The calorie expenditure is calculated from Minetti et al., http://jap.physiology.org/content/93/3/1039.full .
They got their data from elite mountain runners (all male) running on a treadmill.
The outputs seem low compared to other estimates I've seen. This may be because these
elite athletes were very efficient, were not carrying packs or wearing heavy boots, and
were running on a nice uniform treadmill. I find the data most useful if I want to compare
one run to another, e.g., if I want to know how a mountain run with lots of elevation gain
compares with a flat run at a longer distance.
