kcals
=====

This is software that tries to estimate your energy expenditure from
running or walking. Its input is a GPS track in text format.

usage:

   kcals.rb <route.txt ... read parameters from preferences file

   kcals.rb filtering=600 weight=58 <route.txt ... override parameters from command line

Preferences are read from the file ~/.kcals, but can be overridden from the command line
See the file sample_prefs for a sample preferences file.

Parameters are:

  metric -- 0 for US units, 1 for metric
  running -- 0 for walking, 1 for running
  weight -- body mass in kg
  filtering -- see below

Filtering is a parameter with units of meters that defaults to 500, meant to get rid of bogus
oscillations in the height data. I recommend adjusting this in order to reproduce a reliable
figure for the total gain.

Writes total stats to stdout. Also writes some spreadsheet data to 
kcals.csv.
