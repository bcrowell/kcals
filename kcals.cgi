#!/usr/bin/ruby

require 'cgi'
require 'tempfile'
require 'json'
require 'open3'

$home_url = "http://lightandmatter.com/kcals"

cgi = CGI.new # https://ruby-doc.org/stdlib-1.9.3/libdoc/cgi/rdoc/CGI.html

def html_top
  return <<'HTML'
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <title>Kcals - estimate energy consumption when running or walking</title>
  </head>
  <body>
HTML
end

def html_bottom
  return <<'HTML'
  </body>
</html>
HTML
end

def about_method
  return <<"HTML"
    <p>
      The method used to calculate the energy expenditure is from
      <a href="http://jap.physiology.org/content/93/3/1039.full">Minetti et al.
      "Energy cost of walking and running at extreme uphill and downhill slopes,"
      J. Applied Physiology 93 (2002) 1039</a>,
      and is based on laboratory data from elite mountain runners on a treadmill.
      YMMV, and probably most of us are far less efficient than these guys.
      I find the data most useful if I want to compare
      one run to another, e.g., if I want to know how a mountain run with lots of elevation gain
      compares with a flat run at a longer distance.
    </p>
    <p>
      This software is <a href="https://github.com/bcrowell/kcals">open source</a>, and if you prefer
      to run it on your machine rather than through a web interface, you can do that from the unix
      command line.
    </p>
    <p>
      <a href="#{$home_url}">Do another calculation.</a>
    </p>
HTML
end

# Sample results:
# {"horiz":"14.42","horiz_unit":"mi","slope_distance":"14.42","gain":"0","vert_unit":"ft","cost":"1318","warnings":["The input file does not appear to contain any elevation data. Turn on the option 'dem' to try to download this."]} 
def format_output(r)
  if r.has_key?('warnings') then
    r['warnings'].each { |m|
      print "<p>warning: #{m}</p>\n"
    }
  end
  if r.has_key?('error') then
    print "<p>error: #{r['error']}</p>\n"
  end
  print <<"TABLE"
    <table>
      <tr>
        <td>#{$running==1 ? 'running' : 'walking'}</td>
      </tr>
      <tr>
        <td>weight</td>
        <td>#{$weight} kg</td>
      </tr>
      <tr>
        <td>horizontal distance</td>
        <td>#{r['horiz']} #{r['horiz_unit']}</td>
      </tr>
      <tr>
        <td>slope distance</td>
        <td>#{r['slope_distance']} #{r['horiz_unit']}</td>
      </tr>
      <tr>
        <td>gain</td>
        <td>#{r['gain']} #{r['vert_unit']}</td>
      </tr>
      <tr>
        <td>energy expended</td>
        <td>#{r['cost']} kcals</td>
      </tr>
      <tr>
        <td>CF (fraction of effort due to climbing)</td>
        <td>#{r['cf'].to_f*100.0} %</td>
      </tr>
    </table>
TABLE
  print about_method()
end

#---------------------------------------------------------

print cgi.header+"\n"+html_top

if !(cgi.has_key?('file')) then exit(-1) end

cgi_file = cgi['file'] # cgi_file is a StringIO object, which is a string that you can use file methods on

# The following are all based on user input, so we make sure they stay sanitized:
$metric = 0
$running = 1
$format = 'kml'
$weight = 66.0
if cgi.has_key?('metric') && cgi['metric']=='1' then $metric=1 end
if cgi.has_key?('running') && cgi['running']=='0' then $running=0 end
if cgi.has_key?('format') then
  if cgi['format']=='txt' then $format='txt' end
  if cgi['format']=='csv' then $format='csv' end
end
if cgi.has_key?('weight') then $weight=cgi['weight'].to_f end

infile = Tempfile.new('kcals')
begin
  print "<h1>Kcals</h1>\n"
  infile << cgi_file.read # copy CGI upload data into temp file, which we will then read back
  infile.close
  args = {'verbosity'=>0,'dem'=>1,'metric'=>$metric,'running'=>$running,'format'=>$format,'weight'=>$weight,
          'infile'=>infile.path}
  args_json = JSON.generate(args)

  env = ENV.to_hash
  env['CGI'] = '1'
  env['PATH'] = env['PATH']+":"+Dir.pwd
  stdin, stdout, stderr, wait_thr = Open3.popen3(env,Dir.pwd+'/kcals.rb',args_json)
  results_json = stdout.gets(nil)
  stdout.close
  error_output = stderr.gets(nil)
  stderr.close
  exit_code = wait_thr.value

  # comments, for debugging purposes:
  print "<!-- #{args_json} -->\n"
  print "<!-- #{results_json} -->\n"
  print "<!-- error_output=#{error_output} -->\n"
  print "<!-- exit_code=#{exit_code} -->\n"

  if !results_json.nil? then
    results = JSON.parse(results_json)
    print format_output(results)
  end
ensure
  # The following is supposed to happen automatically, but is good practice to do explicitly.
  print html_bottom
  infile.close
  infile.unlink
end
