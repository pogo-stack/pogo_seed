
GREEN='\033[1;32m'
RED='\033[0;31m'
GREY='\033[1;30m'
WHITE='\033[0;37m'
NC='\033[0m' # No Color

echo -e -n "${GREY}"
echo -e -n "${WHITE}processing${GREY} ${WHITE} [$PSQL_DB].[$PSQL_SCHEMA] $1 ${GREY}"
echo -e -n "${NC}"

cnt=`psql "host=$PSQL_HOST port=5432 dbname=$PSQL_DB user=$PSQL_USER options=--search_path=$PSQL_SCHEMA" -t -c "select to_char(min(applied_on), 'dd-Mon-yyyy_hh24:mi') from __pogo__database_scripts where name = '$1'" |head -n 1 |tr -d "| ¤\t"`

if [ "${cnt}" != "" ]
then
    echo -e " - ${GREY}already applied on ${cnt} ${NC}"
else
    psql -q "host=$PSQL_HOST port=5432 dbname=$PSQL_DB user=$PSQL_USER options=--search_path=$PSQL_SCHEMA,public" -v "ON_ERROR_STOP=1" -q --pset pager=off -1 -f "$1" -v role=$PSQL_USER -v database=$PSQL_DB -v schema=$PSQL_SCHEMA -v public_protocol=$POGO_PUBLIC_PROTOCOL -v public_host=$POGO_PUBLIC_HOST
    if [ $? -eq 0 ]; then
        echo -e " - ${GREEN}success. ${NC}"
        psql "host=$PSQL_HOST port=5432 dbname=$PSQL_DB user=$PSQL_USER options=--search_path=$PSQL_SCHEMA" -v "ON_ERROR_STOP=1" -q --pset pager=off -1 -c "insert into __pogo__database_scripts (name, applied_on) values ('$1', current_timestamp)"
    else
        echo -e " - ${RED}error while executing $1 ${NC}"
    fi
fi
