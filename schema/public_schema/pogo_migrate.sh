ls *.sql |while read i; do PGPASSWORD=$PSQL_PASS ./pogo_run_psql.sh "$i" ; done
