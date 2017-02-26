HTML = /var/www
# ... may be /var/www/html on some systems

CGI-BIN = /usr/lib/cgi-bin
BIN = $(CGI-BIN)/kcals
LIB = $(BIN)/lib
SCRATCH = $(BIN)/scratch

default:
	./kcals.rb <sample.txt && head kcals.csv

cgi:
	mkdir -p $(HTML)/kcals
	mkdir -p $(BIN) $(LIB) $(SCRATCH) 
	install kcals.rb kcals.cgi $(BIN)
	install lib/*.rb $(LIB)
	chmod +x /usr/lib/cgi-bin/kcals.rb /usr/lib/cgi-bin/kcals.cgi
	cp kcals.html $(HTML)/kcals/index.html
	chgrp www-data $(SCRATCH)
	chmod g+w $(SCRATCH)

clean-cgi:
	rm -Rf $(HTML)/kcals $(BIN) $(LIB) $(SCRATCH)
