ls *.sql |while read i; do ./pogo_run_psql.sh "$i" ; done
