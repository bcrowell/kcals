#=========================================================================
# @@ low-level file access, shell, command-line arguments
#=========================================================================

# returns contents or nil on error; for more detailed error reporting, see slurp_file_with_detailed_error_reporting()
def slurp_file(file)
  x = slurp_file_with_detailed_error_reporting(file)
  return x[0]
end

# returns [contents,nil] normally [nil,error message] otherwise
def slurp_file_with_detailed_error_reporting(file)
  begin
    File.open(file,'r') { |f|
      t = f.gets(nil) # nil means read whole file
      if t.nil? then t='' end # gets returns nil at EOF, which means it returns nil if file is empty
      return [t,nil]
    }
  rescue
    return [nil,"Error opening file #{file} for input: #{$!}."]
  end
end

def clean_up_temp_files
  shell_out("rm -f #{$temp_files.join(' ')}") if $temp_files.length>0
end

def fatal_error(message)
  if $verbosity>=1 && !$cgi then
    $stderr.print "kcals.rb: #{$verb} fatal error: #{message}\n"
  else
    print JSON.generate({'error'=>message})+"\n"
  end
  exit(-1)
end

def warning(message)
  if $verbosity>=1 && !$cgi then
    $stderr.print "kcals.rb: #{$verb} warning: #{message}\n"
  else
    $warnings.push(message)
  end
end

def shell_out(c,additional_error_info='')
  shell_out_low_level(c,additional_error_info,true)
end

def shell_out_low_level(c,additional_error_info,die_on_error)
  redir = ''
  if $cgi then redir='1>/dev/null 2>/dev/null' end
  full_command = "#{c} #{redir}"
  ok = system(full_command)
  return [true,''] if ok
  message = "error on shell command #{full_command}, #{$?}\n#{additional_error_info}"
  if die_on_error then
    fatal_error(message)
  else
    return [false,message]
  end
end
