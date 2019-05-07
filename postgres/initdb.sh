#!/bin/bash

source /scripts/docker_secret/env_screts_expand.sh

echo "id is : `id -un`"
if [ `id -un` != "postgres" ] ; then
 echo "This script must be run by user postgres"
 exit 1
fi

log_info(){
 echo `date +"%Y-%m-%d %H:%M:%S.%s"` - INFO - $1 
}

function shutdown()
{
  echo "Shutting down PostgreSQL"
  pg_ctl stop
}

#
# return 1 when user exists in postgres, 0 otherwise
#
user_exists(){
 USER=${1}
 psql -c "select usename from pg_user where usename=upper('${USER}')" | grep -q "(0 rows)"
 if  [ $? -eq 0  ] ; then
   echo 0
 else
   echo 1
 fi
}

#
# create two users for the micro-service given as parameter 1, passwords are given as param 2 and 3
# if the users already exist, the password is changed
#
create_user(){
 MSOWNER=${1}
 MSOWNER_PWD=${2}
 PARENT=${3}

 USREXISTS=$(user_exists ${MSOWNER} )
 if [ $USREXISTS -eq 0 ] ; then
  if [ -z ${PARENT} ] ; then
    psql --dbname phoenix <<-EOF
    create user ${MSOWNER} with login password '${MSOWNER_PWD}';
    create schema ${MSOWNER} authorization ${MSOWNER};
    \q
EOF
  else
    USREXISTS=$(user_exists ${MSOWNER} )
    if [ ! $USREXISTS -eq 0 ] ; then
      psql --dbname phoenix <<-EOF
      create user ${MSOWNER} with login password '${MSOWNER_PWD}';
      alter user ${MSOWNER} set search_path to "\$user","${PARENT}", public;
      \q
EOF
      psql --username=${PARENT} --dbname phoenix <<-EOF
      grant usage on schema ${PARENT} to ${MSOWNER};
      alter default privileges in schema ${PARENT} grant select,insert,update,delete on tables to ${MSOWNER};
      alter default privileges in schema ${PARENT} grant usage,select on sequences to ${MSOWNER};
      alter default privileges in schema ${PARENT} grant execute on functions to ${MSOWNER};
      \q
EOF
    fi
  fi
 else
  log_info "user ${MSOWNER} already exists, set password"
  psql --dbname phoenix -c "alter user ${MSOWNER} with login password '${MSOWNER_PWD}';"
 fi
}

wait_for_master(){
 SLEEP_TIME=10
 HOST=${PG_MASTER_NODE_NAME}
 PORT=5432
 NBRTRY=24

 log_info "waiting for master on ${HOST} to be ready"
 nbrlines=0
 while [ $nbrlines -lt 1 -a $NBRTRY -gt 0 ] ; do
  sleep $SLEEP_TIME
  echo "waiting for repmgr node to be initialized with the master"
  psql -U repmgr -h ${HOST} repmgr -t -c "select node_name,active from nodes;" > /tmp/nodes
  if [ $? -ne 0 ] ; then
    echo "cannot connect to $HOST in psql.."
    nbrlines=0
  else
    nbrlines=$( grep -v "^$" /tmp/nodes | wc -l )
  fi
  NBRTRY=$((NBRTRY-1))
 done

}

log_info "Start initdb on host `hostname`"
log_info "PGDATA: ${PGDATA}" 
INITIAL_NODE_TYPE=${INITIAL_NODE_TYPE:-single} 
log_info "INITIAL_NODE_TYPE: ${INITIAL_NODE_TYPE}" 
export PATH=$PATH:/usr/pgsql-${PGVER}/bin
USERS=${USERS-"keycloak,apiman,asset,ingest,playout"}
NODE_ID=${NODE_ID:-1}
NODE_NAME=${NODE_NAME:-"pg0${NODE_ID}"}
ARCHIVELOG=${ARCHIVELOG:-1}
PG_MASTER_NODE_NAME=${PG_MASTER_NODE_NAME:-pg01}
log_info "NODE_ID: $NODE_ID"
log_info "NODE_NAME: $NODE_NAME"
log_info "ARCHIVELOG: $ARCHIVELOG"
log_info "docker: ${docker}"
# automatic or manual
REPMGRD_FAILOVER_MODE=${REPMGRD_FAILOVER_MODE:-manual}
log_info "REPMGRD_FAILOVER_MODE: ${REPMGRD_FAILOVER_MODE}"

create_microservices(){
 IFS=',' read -ra USERVICES <<< "$USERS"
 for USER in ${USERVICES[@]}
 do
    IFS=':' read -ra INFO <<< "$USER"

    ID=""
    PASSWD=""
    PARENT=""

    [[ "${INFO[0]}" != "" ]] && ID="${INFO[0]}"
    [[ "${INFO[1]}" != "" ]] && PASSWD="${INFO[1]}"
    [[ "${INFO[2]}" != "" ]] && PASSWD="${INFO[2]}"

    if [ -z ${PASSWD} ] ; then
      PASSWD=${ID}"_owner"
    fi
    log_info "creating postgres ${ID} users for microservice (Parent : ${PARENT})"
    create_user ${ID} ${PASSWD} ${PARENT}
 done
}

#
# Note that the code below is executed everytime a container is created
# this is needed in order to patch some files that are not persisted accross run
# i.e. files that are outside the PGDATA directory (PGDATA being on shared volume)
#
log_info "create repmgr user or change password"
if [ ! -z ${REPMGRPWD} ] ; then
  log_info "repmgr password set via env"
else
  REPMGRPWD=rep123
  log_info "repmgr password default to rep123"
fi
USREXISTS=$(user_exists repmgr )
if [ $USREXISTS -eq 0 ] ; then
  psql <<-EOF
      create user repmgr with superuser login password '${REPMGRPWD}' ;
      alter user repmgr set search_path to repmgr,"\$user",public;
      \q
EOF
else
  log_info "user repmgr already exists, set password"
  psql -c "alter user repmgr with login password '${REPMGRPWD}';"
fi
log_info "setup .pgpass for replication and for repmgr"
echo "*:*:repmgr:repmgr:${REPMGRPWD}" > /home/postgres/.pgpass
echo "*:*:replication:repmgr:${REPMGRPWD}" >> /home/postgres/.pgpass
chmod 600 /home/postgres/.pgpass

# patch script /scripts/repmgrd_event.sh 
sed -i -e "s/##REPMGRD_FAILOVER_MODE##/${REPMGRD_FAILOVER_MODE}/" /scripts/repmgrd_event.sh
#build repmgr.conf
sudo touch /etc/repmgr/${PGVER}/repmgr.conf && sudo chown postgres:postgres /etc/repmgr/${PGVER}/repmgr.conf
cat <<EOF > /etc/repmgr/${PGVER}/repmgr.conf
node_id=${NODE_ID}
node_name=${NODE_NAME}
conninfo='host=${NODE_NAME} dbname=repmgr user=repmgr password=${REPMGRPWD} connect_timeout=2'
data_directory='/data'
use_replication_slots=1
restore_command = 'cp /u02/archive/%f %p'

#log_file='/var/log/repmgr/repmgr.log'
log_facility=STDERR
failover=${REPMGRD_FAILOVER_MODE}
reconnect_attempts=${REPMGRD_RECONNECT_ATTEMPS:-6}
reconnect_interval=${REPMGRD_INTERVAL:-5}
event_notification_command='/scripts/repmgrd_event.sh %n "%e" %s "%t" "%d" %p %c %a'
monitor_interval_secs=5

pg_bindir='/usr/pgsql-${PGVER}/bin'

service_start_command = 'sudo supervisorctl start postgres'
service_stop_command = 'sudo supervisorctl stop postgres'
service_restart_command = 'sudo supervisorctl restart postgres'
service_reload_command = 'pg_ctl reload'

promote_command='repmgr -f /etc/repmgr/${PGVER}/repmgr.conf standby promote'
follow_command='repmgr -f /etc/repmgr/${PGVER}/repmgr.conf standby follow -W --upstream-node-id=%n'

EOF

log_info "set password for postgres"
if [ ! -z ${POSTGRES_PWD} ] ; then
  log_info "postgres password set via env"
else
  POSTGRES_PWD=${REPMGRPWD}
  log_info "postgres password default to REPMGRPWD"
fi
psql --command "alter user postgres with login password '${POSTGRES_PWD}';"
echo postgres:${POSTGRES_PWD} | chpasswd
echo "*:*:postgres:${POSTGRES_PWD}" > /home/postgres/.pcppass && chown postgres:postgres /home/postgres/.pcppass && chmod 600 /home/postgres/.pcppass

log_info "Create hcuser"
if [ ! -z ${HEALTH_CHECK_PWD} ] ; then
  log_info "health_check_user password set via env"
else
  HEALTH_CHECK_PWD=hcuser
  log_info "health_check_user password default to hcuser"
fi
if [ $USREXISTS -eq 0 ] ; then
  psql -c "create user hcuser with login password '${HEALTH_CHECK_PWD}';"
else
  log_info "user hcuser already exists, set password"
  psql -c "alter user hcuser with login password '${HEALTH_CHECK_PWD}';"
fi

create_microservices

#
# stuff below will be done only once, when the database has not been initialized
#
#
if [ ! -f ${PGDATA}/postgresql.conf ] ; then
  log_info "$PGDATA/postgresql.conf does not exist"
  if [[ "a$INITIAL_NODE_TYPE" != "aslave" ]] ; then
    log_info "This node is the master or we are in a single db setup, let us init the db"
    pg_ctl initdb -D ${PGDATA} -o "--encoding='UTF8' --locale='en_US.UTF8'"
    log_info "Adding include_dir in $PGDATA/postgresql.conf"
    mkdir $PGDATA/conf.d
    cp /opt/pgconfig/01custom.conf $PGDATA/conf.d
    echo "include_dir = './conf.d'" >> $PGDATA/postgresql.conf
    cat <<-EOF >> $PGDATA/pg_hba.conf
# replication manager
local  replication   repmgr                      trust
host   replication   repmgr      127.0.0.1/32    trust
host   replication   repmgr      0.0.0.0/0       md5
local   repmgr        repmgr                     trust
host    repmgr        repmgr      127.0.0.1/32   trust
host    repmgr        repmgr      0.0.0.0/0      md5
EOF
    echo "host     all           all        0.0.0.0/0            md5" >> $PGDATA/pg_hba.conf
    echo starting database
    ps -ef
    pg_ctl -D ${PGDATA} start -o "-c 'listen_addresses=localhost'" -w 
    psql --command "create database phoenix ENCODING='UTF8' LC_COLLATE='en_US.UTF8';"
    psql phoenix -c "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"";
    log_info "Creating repmgr database"
    # NB: super user needed for replication
    psql --command "create database repmgr with owner=repmgr ENCODING='UTF8' LC_COLLATE='en_US.UTF8';"
    if [ -f /usr/pgsql-${PGVER}/share/extension/pgpool-recovery.sql ] ; then
      log_info "pgpool extensions"
      psql -c "create extension pgpool_recovery;" -d template1
      psql -c "create extension pgpool_adm;"
    else
      log_info "pgpool-recovery.sql extension not found"
    fi
    cp /scripts/pgpool/pgpool_recovery.sh /scripts/pgpool/pgpool_remote_start ${PGDATA}/
    chmod 700 ${PGDATA}/pgpool_remote_start ${PGDATA}/pgpool_recovery.sh
   
    echo "ARCHIVELOG=$ARCHIVELOG" > $PGDATA/override.env
    echo "Start postgres again to register master"
    pg_ctl stop
    pg_ctl start -w
    log_info "Register master in repmgr"
    repmgr -f /etc/repmgr/${PGVER}/repmgr.conf -v master register
    pg_ctl stop
  else
    log_info "This is a slave. Wait that master is up and running"
    wait_for_master
    if [ $? -eq 0 ] ; then
     log_info "Master ready, sleep 10 seconds before cloning slave"
     sleep 10
     sudo rm -rf ${PGDATA}/*
     repmgr -h ${PG_MASTER_NODE_NAME} -U repmgr -d repmgr -D ${PGDATA} -f /etc/repmgr/${PGVER}/repmgr.conf standby clone
     pg_ctl -D ${PGDATA} start -w
     repmgr -f /etc/repmgr/${PGVER}/repmgr.conf standby register
     pg_ctl stop
    else
     log_info "Master is not ready, standby will not be initialized"
    fi
  fi
else
  log_info "File ${PGDATA}/postgresql.conf already exist"
fi
#TODO: this trap is not used
trap shutdown HUP INT QUIT ABRT KILL ALRM TERM TSTP
ps -ef
log_info "start postgres in foreground"
exec postgres -D ${PGDATA} 
