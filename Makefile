HTML = /var/www
# ... may be /var/www/html on some systems

default:
	./kcals.rb <sample.txt && head kcals.csv

cgi:
	cp kcals.rb /usr/lib/cgi-bin
	cp kcals.cgi /usr/lib/cgi-bin
	chmod +x /usr/lib/cgi-bin/kcals.rb /usr/lib/cgi-bin/kcals.cgi
	mkdir $(HTML)/kcals
	cp kcals.html $(HTML)/kcals/index.html
	mkdir /usr/lib/cgi-bin/kcals_scratch
	chgrp www-data /usr/lib/cgi-bin/kcals_scratch
	chmod g+w /usr/lib/cgi-bin/kcals_scratch

clean-cgi:
	rm -Rf /usr/lib/cgi-bin/kcals_scratch
	rm -Rf /var/www/kcals
