#!/usr/bin/ruby

require 'cgi'
require 'tempfile'
require 'json'

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

# Sample results:
# {"horiz":"14.42","horiz_unit":"mi","slope_distance":"14.42","gain":"0","vert_unit":"ft","cost":"1318","warnings":["The input file does not appear to contain any elevation data. Turn on the option 'dem' to try to download this."]} 
def format_output(r)
  print <<"TABLE"
    <table>
      <tr>
        <td>horizontal distance</td>
        <td>#{r['horiz']} #{r['horiz_unit']}</td>
      </tr>
    </table>
TABLE
end

#---------------------------------------------------------

print cgi.header+"\n"+html_top

if !(cgi.has_key?('file')) then exit(-1) end

cgi_file = cgi['file'] # cgi_file is a StringIO object, which is a string that you can use file methods on

infile = Tempfile.new('kcals')
begin
  print "<h1>Kcals</h1>\n"
  #print "<p>#{Dir.pwd}</p>\n"
  infile << cgi_file.read # copy CGI upload data into temp file, which we will then read back
  #print `cat #{infile.path}`
  json = `CGI=1 ./kcals.rb verbosity=0 <#{infile.path}` # verbosity=0 makes it output json data
  print "<!-- #{json} -->\n" # for debugging purposes
  results = JSON.parse(json)
  print format_output(results)
ensure
  # The following is supposed to happen automatically, but is good practice to do explicitly.
  print html_bottom
  infile.close
  infile.unlink
end
