#!/bin/bash

CONFIG_DIR=/etc/pgpool-II
CONFIG_FILE=${CONFIG_DIR}/pgpool.conf
PCP_FILE=${CONFIG_DIR}/pcp.conf
HBA_FILE=${CONFIG_DIR}/pool_hba.conf

is_db_up(){
  echo "Is DB up for host ${1} port ${2:-5432} ?"
  ssh -p 222 -oPasswordAuthentication=no ${1} uname
  ret=$?
  if [ $ret -ne 0 ] ; then
    echo Cannot connect to host $1 via ssh
    return 0
  fi
  echo Try psql connection on host $1 port ${2:-5432}
  # we could use pg_is_ready also
  ssh -p 222 -oPasswordAuthentication=no $1 "psql --username=repmgr -p ${2:-5432} repmgr -c \"select 1;\""
  ret=$?
  if [ $ret -ne 0 ] ; then
    return 0
  fi
  return 1
}


wait_for_any_db(){
  SLEEP_TIME=5
  while [ 0 -eq 0 ] ; do
    echo "Using list of backend $PG_BACKEND_NODE_LIST to find a db to connect to"
    i=0
    while [ $i -lt ${#PG_HOSTS[@]} ] ; do
      echo trying with ${PG_HOSTS[$i]}
      DBHOST=$( echo ${PG_HOSTS[$i]} | cut -f2 -d":" )
      PORT=$( echo ${PG_HOSTS[$i]} | cut -f3 -d":" )
      if [ -z $PORT ] ; then
        PORT=5432
      fi
      is_db_up $DBHOST $PORT
      if [ $? -ne 1 ] ; then
        i=$((i+1))
      else
        echo "server ${DBHOST} ready"
        echo "pg backend found at host $DBHOST and port $PORT"
        return 0
      fi
    done
    sleep $SLEEP_TIME
  done
}

wait_for_one_db(){
  waitfor=$1
  waitport=${2:5432}
  maxtries=${3:-12}
  i=0
  while [ $i -lt $maxtries ] ; do
    is_db_up $waitfor $waitport
    if [ $? -eq 1 ] ; then
      return 0
    else
      i=$((i+1))
      sleep 5
    fi
    echo Waiting for $waitfor, tried $i times out of $maxtries
  done
  return 1
}

build_pgpool_status_file(){
  h=${1}

  psql -h ${h} -U repmgr repmgr -t -c "select node_name,active,type from nodes;" > /tmp/repl_nodes
  echo ">>>repl_nodes:"
  cat /tmp/repl_nodes
  > /tmp/pgpool_status
  # Collect info on all backends: is it up, in_recovery and repmgr status
  > /tmp/backendsinfo.txt
  for i in ${PG_HOSTS[@]}
  do
    h=$( echo $i | cut -f2 -d":" )
    p=$( echo $i | cut -f3 -d":" )
    echo "check state of $h in repl_nodes"
    repm_active=$( grep $h /tmp/repl_nodes | sed -e "s/ //g" | cut -f2 -d"|" )
    repm_type=$( grep $h /tmp/repl_nodes | sed -e "s/ //g" | cut -f3 -d"|" )
    echo "repm_active is $repm_active and repm_type is $repm_type for $h"
    if [ "a$repm_type" == "aprimary" ] ; then
      REPMGR_MASTER=$h
      REPMGR_MASTER_PORT=$p
    fi
    is_db_up $h $p
    if [ $? -eq 1 ] ; then
      dbup=t
      inreco=$( psql -h $h -p $p -U repmgr -t -c "select pg_is_in_recovery();")
    else
      dbup=f
      inreco=?
    fi
    echo "${h}:dbup=${dbup}:repm_active=${repm_active}:repm_type=${repm_type}:inrecovery=${inreco}" | sed -e "s/ //g" >> /tmp/backendsinfo.txt
    if [ "a$repm_active" == "at" ] ; then
      echo $h is up in repl_nodes
      echo up >> /tmp/pgpool_status
    fi
    if [ "a$repm_active" == "af" ] ; then
      echo $h is down in repl_nodes
      echo down >> /tmp/pgpool_status
    fi
    if [ "a$repm_active" == "a" ] ; then
      (>&2 echo "backend $h is not found in repl_nodes, marking as up")
      echo up >> /tmp/pgpool_status
    fi
  done
  echo ">>> backendsinfo.txt"
  cat /tmp/backendsinfo.txt

  echo ">>> pgpool_status file"
  cat /tmp/pgpool_status
}


getIdFromHost(){
  echo $PG_BACKEND_NODE_LIST | tr ',' '\n' | while read line
  do
    #echo $line
    n=$( echo $line | cut -d":" -f1 )
    h=$( echo $line | cut -d":" -f2 )
    if [ $h == $1 ] ; then
      echo $n
      return
    fi
  done
}

log_info(){
  echo "$(date +"%Y%m%d %H:%M:%S.%s") - INFO - $1"
}

updateConfig(){
  CONFIG=$1
  VALUE=$2
  log_info "Injecting config $CONFIG with value $VALUE in $CONFIG_FILE"
  # remove value first
  sed -i -e "/^${CONFIG}\s*=/d" $CONFIG_FILE
  echo "${CONFIG} = ${VALUE}" >> $CONFIG_FILE
}

 

injectConfigsFromEnv(){
  # inject configuration from env variables prefixed with PGPOOL_
  OLD_IFS=$IFS
  IFS=$'\n'
  echo "### generated ###" >> $CONFIG_FILE
  for VAR in $(env)
  do
    env_var=$(echo "$VAR" | cut -d= -f1)
    if [[ $env_var =~ ^PGPOOL_ ]]; then
      config_name=$(echo "$env_var" | cut -d_ -f2- | tr '[:upper:]' '[:lower:]' )
      updateConfig "$config_name" "${!env_var}"
    fi
  done
  IFS=$OLD_IFS
}


PG_MASTER_NODE_NAME=${PG_MASTER_NODE_NAME:-pg01}
echo PG_MASTER_NODE_NAME=${PG_MASTER_NODE_NAME}
PG_BACKEND_NODE_LIST=${PG_BACKEND_NODE_LIST:-0:${PG_MASTER_NODE_NAME}:5432}
echo PG_BACKEND_NODE_LIST=${PG_BACKEND_NODE_LIST}
PGP_NODE_NAME=${PGP_NODE_NAME:-pgpool01}
echo PGP_NODE_NAME=${PGP_NODE_NAME}
REPMGRPWD=${REPMGRPWD:-rep123}
echo REPMGRPWD=${REPMGRPWD}
FAILOVER_ON_BACKEND_ERROR=${FAILOVER_ON_BACKEND_ERROR:-off}
echo FAILOVER_ON_BACKEND_ERROR=${FAILOVER_ON_BACKEND_ERROR}
CONNECTION_CACHE=${CONNECTION_CACHE:-on}
echo CONNECTION_CACHE=${CONNECTION_CACHE}

if [ ! -z ${POSTGRES_PWD} ] ; then
  log_info "postgres password set via env"
else
  POSTGRES_PWD=${REPMGRPWD}
  log_info "postgres password default to REPMGRPWD"
fi

echo postgres:${POSTGRES_PWD} | sudo chpasswd
echo "postgres:`pg_md5 --config-file $CONFIG_FILE ${POSTGRES_PWD}`" >> $PCP_FILE
echo "*:*:postgres:${POSTGRES_PWD}" > /home/postgres/.pcppass

IFS=',' read -ra PG_HOSTS <<< "$PG_BACKEND_NODE_LIST"
nbrbackend=${#PG_HOSTS[@]}
if [ $nbrbackend -gt 1 ] ; then
  MASTER_SLAVE_MODE=on
else
  MASTER_SLAVE_MODE=off
  FAILOVER_MODE=manual
fi
echo MASTER_SLAVE_MODE=$MASTER_SLAVE_MODE
FAILOVER_MODE=${FAILOVER_MODE:-automatic}
echo FAILOVER_MODE=${FAILOVER_MODE}

# make connections via psql convenient
echo "*:*:repmgr:repmgr:${REPMGRPWD}" > /home/postgres/.pgpass
chmod 600 /home/postgres/.pgpass


echo "Waiting for any of the database to be ready"
wait_for_any_db
echo "Checking backend databases state in repl_nodes table"
# if the cluster is initializing it is possible that repl_nodes does not contain
# all backend yet and so we might need to wait a bit...
psql -h ${DBHOST} -U repmgr repmgr -t -c "select node_name,active,type from nodes;" > /tmp/repl_nodes
if [ $? -ne 0 ] ; then
  echo "error connecting to $DBHOST, this likely indicates an unexpected issue"
fi
nbrlines=$( grep -v "^$" /tmp/repl_nodes | wc -l )
NBRTRY=30
while [ $nbrlines -lt $nbrbackend -a $NBRTRY -gt 0 ] ; do
  echo "waiting for repl_nodes to be initialized: currently $nbrlines in repl_node, there must be one line per back-end ($nbrbackend)"
  psql -h ${DBHOST} -U repmgr repmgr -t -c "select node_name,active,type from nodes;" > /tmp/repl_nodes
  nbrlines=$( grep -v "^$" /tmp/repl_nodes | wc -l )
  NBRTRY=$((NBRTRY-1))
  echo "Sleep 10 seconds, still $NBRTRY to go..."
  sleep 10
done
if [ -f /tmp/.not_host_mounted ] ; then
 # if we can see this file it means that /tmp is not host mounted
 build_pgpool_status_file ${DBHOST}
 echo REPMGR_MASTER is ${REPMGR_MASTER}
 # issue: assume the master is pg02 and it was stopped outside the control of pgpool (after pgpool was stopped)
 # then pgpool will search for a master for search_primary_node_timeout then it will do a failover
 # however in the failover it will say : falling node = 1, old_primary = 0 and so the failover will do nothing
 echo Get state of REPMGR_MASTER $REPMGR_MASTER
 master_info=$( grep "^${REPMGR_MASTER}:" /tmp/backendsinfo.txt )
 echo $master_info | grep dbup=t
 if [ $? -eq 0 ] ; then
   masterup=1
   echo master database is up
 else
   masterup=0
   echo master database is down
 fi
else
 # so that we skip the logic below
 echo "/tmp is mounted from the host, will reuse /tmp/pgpool_status" 
 masterup=1
fi
if [ $masterup -eq 0 -a ${FAILOVER_MODE} == "automatic" ] ; then
  echo master database is down and FAILOVER_MODE is auto, wait 1 minute before doing promotion
  wait_for_one_db ${REPMGR_MASTER} ${REPMGR_MASTER_PORT} 12
  echo check again
  is_db_up ${REPMGR_MASTER} ${REPMGR_MASTER_PORT}
  if [ $? -ne 1 ] ; then
     echo I will promote another database
     HOST2PROMOTE=$( grep "repm_type=standby" /tmp/backendsinfo.txt | grep "dbup=t" | head -1 | cut -f1 -d":" )
     echo Promoting $HOST2PROMOTE
     ssh -p 222 ${HOST2PROMOTE} -C "/scripts/promote_me.sh"
     echo Server ${HOST2PROMOTE} promoted to primary, waiting 10 seconds before starting pgpool
     sleep 10
     echo Promotion done, rebuilding the pgpool_status file
     build_pgpool_status_file ${HOST2PROMOTE}
     echo Get state of REPMGR_MASTER $REPMGR_MASTER
     master_info=$( grep "^${REPMGR_MASTER}:" /tmp/backendsinfo.txt )
     echo $master_info
     echo $master_info | grep dbup=t
     if [ $? -eq 0 ] ; then
       echo master is up
     else
       echo FATAL Master is down, this will not work
     fi
  fi
fi

echo "Create user hcuser (fails if the hcuser already exists, which is ok)"
ssh -p 222 ${REPMGR_MASTER} "psql -c \"create user hcuser with login password '${HEALTH_CHECK_PWD}';\""
echo "Generate pool_passwd file from ${DBHOST}"
touch ${CONFIG_DIR}/pool_passwd
ssh -p 222 postgres@${DBHOST} "psql -c \"select rolname,rolpassword from pg_authid;\"" | awk 'BEGIN {FS="|"}{print $1" "$2}' | grep md5 | while read f1 f2
do
 # delete the line and recreate it
 echo "setting passwd of $f1 in ${CONFIG_DIR}/pool_passwd"
 sed -i -e "/^${f1}:/d" ${CONFIG_DIR}/pool_passwd
 echo $f1:$f2 >> ${CONFIG_DIR}/pool_passwd
done
echo "Builing the configuration in $CONFIG_FILE"

cat <<EOF > $CONFIG_FILE
# config file generated by entrypoint at `date`
listen_addresses = '*'
port = 9999
socket_dir = '/var/run/pgpool'
pcp_listen_addresses = '*'
pcp_port = 9898
pcp_socket_dir = '/var/run/pgpool'
listen_backlog_multiplier = 2
serialize_accept = off
EOF
echo "Adding backend-connection info for each pg node in $PG_BACKEND_NODE_LIST"
IFS=',' read -ra HOSTS <<< "$PG_BACKEND_NODE_LIST"
for HOST in ${HOSTS[@]}
do
    IFS=':' read -ra INFO <<< "$HOST"

    NUM=""
    HOST=""
    PORT="9999"
    WEIGHT=1
    DIR="/data"
    FLAG="ALLOW_TO_FAILOVER"

    [[ "${INFO[0]}" != "" ]] && NUM="${INFO[0]}"
    [[ "${INFO[1]}" != "" ]] && HOST="${INFO[1]}"
    [[ "${INFO[2]}" != "" ]] && PORT="${INFO[2]}"
    [[ "${INFO[3]}" != "" ]] && WEIGHT="${INFO[3]}"
    [[ "${INFO[4]}" != "" ]] && DIR="${INFO[4]}"
    [[ "${INFO[5]}" != "" ]] && FLAG="${INFO[5]}"

    echo "
backend_hostname$NUM = '$HOST'
backend_port$NUM = $PORT
backend_weight$NUM = $WEIGHT
backend_data_directory$NUM = '$DIR'
backend_flag$NUM = '$FLAG'
" >>  $CONFIG_FILE
done
cat <<EOF >> $CONFIG_FILE
# - Authentication -
enable_pool_hba = on
pool_passwd = 'pool_passwd'
authentication_timeout = 60
ssl = off
#------------------------------------------------------------------------------
# POOLS
#------------------------------------------------------------------------------
# - Concurrent session and pool size -
num_init_children = ${NUM_INIT_CHILDREN:-62}
                                   # Number of concurrent sessions allowed
                                   # (change requires restart)
max_pool = ${MAX_POOL:-4}
                                   # Number of connection pool caches per connection
                                   # (change requires restart)
# - Life time -
child_life_time = 300
                                   # Pool exits after being idle for this many seconds
child_max_connections = 0
                                   # Pool exits after receiving that many connections
                                   # 0 means no exit
connection_life_time = 0
                                   # Connection to backend closes after being idle for this many seconds
                                   # 0 means no close
client_idle_limit = 0
                                   # Client is disconnected after being idle for that many seconds
                                   # (even inside an explicit transactions!)
                                   # 0 means no disconnection
#------------------------------------------------------------------------------
# LOGS
#------------------------------------------------------------------------------

# - Where to log -

log_destination = 'stderr'
                                   # Where to log
                                   # Valid values are combinations of stderr,
                                   # and syslog. Default to stderr.

# - What to log -

log_line_prefix = '%t: pid %p: '   # printf-style string to output at beginning of each log line.

log_connections = on
                                   # Log connections
log_hostname = on
                                   # Hostname will be shown in ps status
                                   # and in logs if connections are logged
log_statement = ${LOG_STATEMENT:-off}
                                   # Log all statements
log_per_node_statement = off
                                   # Log all statements
                                   # with node and backend informations
log_standby_delay = 'if_over_threshold'
                                   # Log standby delay
                                   # Valid values are combinations of always,
                                   # if_over_threshold, none

# - syslog specific -

syslog_facility = 'LOCAL0'
                                   # Syslog local facility. Default to LOCAL0
syslog_ident = 'pgpool'
                                   # Syslog program identification string
                                   # Default to 'pgpool'
debug_level = ${DEBUG_LEVEL:-0}
                                   # Debug message verbosity level
                                   # 0 means no message, 1 or more mean verbose
log_error_verbosity = verbose          # terse, default, or verbose messages
#------------------------------------------------------------------------------
# FILE LOCATIONS
#------------------------------------------------------------------------------

pid_file_name = '/var/run/pgpool/pgpool.pid'
                                   # PID file name
                                   # (change requires restart)
logdir = '/tmp'
                                   # Directory of pgPool status file
                                   # (change requires restart)
#------------------------------------------------------------------------------
# CONNECTION POOLING
#------------------------------------------------------------------------------

connection_cache = ${CONNECTION_CACHE}
                                   # Activate connection pools
                                   # (change requires restart)

                                   # Semicolon separated list of queries
                                   # to be issued at the end of a session
                                   # The default is for 8.3 and later
reset_query_list = 'ABORT; DISCARD ALL'
                                   # The following one is for 8.2 and before
#reset_query_list = 'ABORT; RESET ALL; SET SESSION AUTHORIZATION DEFAULT'
#------------------------------------------------------------------------------
# REPLICATION MODE
#------------------------------------------------------------------------------
replication_mode = off
#------------------------------------------------------------------------------
# LOAD BALANCING MODE
#------------------------------------------------------------------------------

load_balance_mode = ${MASTER_SLAVE_MODE}
                                   # Activate load balancing mode
                                   # (change requires restart)
ignore_leading_white_space = on
                                   # Ignore leading white spaces of each query
white_function_list = ''
                                   # Comma separated list of function names
                                   # that don't write to database
                                   # Regexp are accepted
black_function_list = 'currval,lastval,nextval,setval'
                                   # Comma separated list of function names
                                   # that write to database
                                   # Regexp are accepted

database_redirect_preference_list = ''
                                                                   # comma separated list of pairs of database and node id.
                                                                   # example: postgres:primary,mydb[0-4]:1,mydb[5-9]:2'
                                                                   # valid for streaming replicaton mode only.

app_name_redirect_preference_list = ''
                                                                   # comma separated list of pairs of app name and node id.
                                                                   # example: 'psql:primary,myapp[0-4]:1,myapp[5-9]:standby'
                                                                   # valid for streaming replicaton mode only.
allow_sql_comments = off
                                                                   # if on, ignore SQL comments when judging if load balance or
                                                                   # query cache is possible.
                                                                   # If off, SQL comments effectively prevent the judgment
                                                                   # (pre 3.4 behavior).
#------------------------------------------------------------------------------
# MASTER/SLAVE MODE
#------------------------------------------------------------------------------

master_slave_mode = ${MASTER_SLAVE_MODE}
                                   # Activate master/slave mode
                                   # (change requires restart)
master_slave_sub_mode = 'stream'
                                   # Master/slave sub mode
                                   # Valid values are combinations slony or
                                   # stream. Default is slony.
                                   # (change requires restart)

# - Streaming -

sr_check_period = 10
                                   # Streaming replication check period
                                   # Disabled (0) by default
sr_check_user = 'repmgr'
                                   # Streaming replication check user
                                   # This is neccessary even if you disable streaming
                                   # replication delay check by sr_check_period = 0
sr_check_password = '${REPMGRPWD}'
                                   # Password for streaming replication check user
sr_check_database = 'repmgr'
                                   # Database name for streaming replication check
delay_threshold = 10000000
                                   # Threshold before not dispatching query to standby node
                                   # Unit is in bytes
                                   # Disabled (0) by default

#------------------------------------------------------------------------------
# HEALTH CHECK
#------------------------------------------------------------------------------

health_check_period = 40
                                   # Health check period
                                   # Disabled (0) by default
health_check_timeout = 10
                                   # Health check timeout
                                   # 0 means no timeout
health_check_user = 'hcuser'
                                   # Health check user
health_check_password = '${HEALTH_CHECK_PWD}'
                                   # Password for health check user
health_check_database = 'postgres'
                                   # Database name for health check. If '', tries 'postgres' frist,
health_check_max_retries = 3
                                   # Maximum number of times to retry a failed health check before giving up.
health_check_retry_delay = 1
                                   # Amount of time to wait (in seconds) between retries.
connect_timeout = 10000
                                   # Timeout value in milliseconds before giving up to connect to backend.
                                                                   # Default is 10000 ms (10 second). Flaky network user may want to increase
                                                                   # the value. 0 means no timeout.
                                                                   # Note that this value is not only used for health check,
                                                                   # but also for ordinary conection to backend.
#------------------------------------------------------------------------------
# FAILOVER AND FAILBACK
#------------------------------------------------------------------------------
EOF
if [ $FAILOVER_MODE == "automatic" ] ; then
  cat <<EOF >> $CONFIG_FILE
failover_command = '/scripts/failover.sh %d %h %p %D %m %H %M %P %r %R'
                                   # Executes this command at failover
                                   # Special values:
                                   #   %d = node id
                                   #   %h = host name
                                   #   %p = port number
                                   #   %D = database cluster path
                                   #   %m = new master node id
                                   #   %H = hostname of the new master node
                                   #   %M = old master node id
                                   #   %P = old primary node id
                                   #   %r = new master port number
                                   #   %R = new master database cluster path
                                   #   %% = '%' character
failback_command = './scripts/failback.sh %d %h %p %D %m %H %M %P'
                                   # Executes this command at failback.
                                   # Special values:
                                   #   %d = node id
                                   #   %h = host name
                                   #   %p = port number
                                   #   %D = database cluster path
                                   #   %m = new master node id
                                   #   %H = hostname of the new master node
                                   #   %M = old master node id
                                   #   %P = old primary node id
                                                                   #   %r = new master port number
                                                                   #   %R = new master database cluster path
                                   #   %% = '%' character
follow_master_command = '/scripts/follow_master.sh %d %h %m %p %H %M %P'
                                   # Executes this command after master failover
                                   # Special values:
                                   #   %d = node id
                                   #   %h = host name
                                   #   %p = port number
                                   #   %D = database cluster path
                                   #   %m = new master node id
                                   #   %H = hostname of the new master node
                                   #   %M = old master node id
                                   #   %P = old primary node id
                                                                   #   %r = new master port number
                                                                   #   %R = new master database cluster path
                                   #   %% = '%' character
EOF
else 
  cat <<EOF >> $CONFIG_FILE
failover_command = ''
failback_command = '' 
follow_master_command = '' 
EOF
fi

cat <<EOF >> $CONFIG_FILE
failover_on_backend_error = ${FAILOVER_ON_BACKEND_ERROR}
                                   # Initiates failover when reading/writing to the
                                   # backend communication socket fails
                                   # If set to off, pgpool will report an
                                   # error and disconnect the session.

search_primary_node_timeout = 0
                                   # Timeout in seconds to search for the
                                   # primary node when a failover occurs.
                                   # 0 means no timeout, keep searching
                                   # for a primary node forever.

#------------------------------------------------------------------------------
# ONLINE RECOVERY
#------------------------------------------------------------------------------

recovery_user = 'postgres'
                                   # Online recovery user
recovery_password = '${POSTGRES_PWD}'
                                   # Online recovery password
recovery_1st_stage_command = 'pgpool_recovery.sh'
                                   # Executes a command in first stage
recovery_2nd_stage_command = 'echo recovery_2nd_stage_command'
                                   # Executes a command in second stage
recovery_timeout = 90
                                   # Timeout in seconds to wait for the
                                   # recovering node's postmaster to start up
                                   # 0 means no wait
client_idle_limit_in_recovery = 0
                                   # Client is disconnected after being idle
                                   # for that many seconds in the second stage
                                   # of online recovery
                                   # 0 means no disconnection
                                   # -1 means immediate disconnection
#------------------------------------------------------------------------------
# WATCHDOG
#------------------------------------------------------------------------------

# - Enabling -
EOF
if [ ! -z $DELEGATE_IP ] ; then
 echo "watchdog set to on because DELETEGATE_IP is set to $DELEGATE_IP"
 DELEGATE_IP_MASK=$(echo $DELEGATE_IP | cut -f2 -d"/")
 DELEGATE_IP_IP=$(echo $DELEGATE_IP | cut -f1 -d"/")
 echo "use_watchdog = on" >> $CONFIG_FILE
else
 echo "watchdog set to off because DELEGATE_IP is not set"
 echo "use_watchdog = off" >> $CONFIG_FILE
fi
if [ ! -z ${TRUSTED_SERVERS} ] ; then
  cat <<EOF >> $CONFIG_FILE
# -Connection to up stream servers -
trusted_servers = '${TRUSTED_SERVERS}'
                                    # trusted server list which are used
                                    # to confirm network connection
                                    # (hostA,hostB,hostC,...)
                                    # (change requires restart)
EOF
fi
cat <<EOF >> $CONFIG_FILE
ping_path = '/bin'
                                    # ping command path
                                    # (change requires restart)

# - Watchdog communication Settings -
EOF
echo "wd_hostname = '${PGP_NODE_NAME}'" >> $CONFIG_FILE
cat <<EOF >> $CONFIG_FILE
                                    # Host name or IP address of this watchdog
                                    # (change requires restart)
wd_port = 9000
                                    # port number for watchdog service
                                    # (change requires restart)
wd_priority = 1
                                                                        # priority of this watchdog in leader election
                                                                        # (change requires restart)

wd_authkey = ''
                                    # Authentication key for watchdog communication
                                    # (change requires restart)

wd_ipc_socket_dir = '/var/run/pgpool'
                                                                        # Unix domain socket path for watchdog IPC socket
                                                                        # The Debian package defaults to
                                                                        # /var/run/postgresql
                                                                        # (change requires restart)
EOF
if [ ! -z ${DELEGATE_IP} ] ; then
  cat <<EOF >> $CONFIG_FILE
# - Virtual IP control Setting -

delegate_IP = '${DELEGATE_IP_IP}'
                                    # delegate IP address
                                    # If this is empty, virtual IP never bring up.
                                    # (change requires restart)
if_cmd_path = '/scripts'
                                    # path to the directory where if_up/down_cmd exists
                                    # (change requires restart)
if_up_cmd = 'ip_w.sh addr add \$_IP_\$/${DELEGATE_IP_MASK:-24} dev ${DELEGATE_IP_INTERFACE:-eth0} label ${DELEGATE_IP_INTERFACE:-eth0}:0'
                                    # startup delegate IP command
                                    # (change requires restart)
if_down_cmd = 'ip_w.sh addr del \$_IP_\$/${DELEGATE_IP_MASK:-24} dev ${DELEGATE_IP_INTERFACE:-eth0}'
                                    # shutdown delegate IP command
                                    # (change requires restart)
arping_path = '/scripts'
                                    # arping command path
                                    # (change requires restart)
arping_cmd = 'arping_w.sh -U \$_IP_\$ -I ${DELEGATE_IP_INTERFACE:-eth0} -w 1'
                                    # arping command
                                    # (change requires restart)

# - Behaivor on escalation Setting -

clear_memqcache_on_escalation = on
                                    # Clear all the query cache on shared memory
                                    # when standby pgpool escalate to active pgpool
                                    # (= virtual IP holder).
                                    # This should be off if client connects to pgpool
                                    # not using virtual IP.
                                    # (change requires restart)
wd_escalation_command = ''
                                    # Executes this command at escalation on new active pgpool.
                                    # (change requires restart)
wd_de_escalation_command = ''
                                                                        # Executes this command when master pgpool resigns from being master.
                                                                        # (change requires restart)
EOF
fi
echo "heartbeat set-up"
IFS=',' read -ra HBEATS <<< "$PGP_HEARTBEATS"
for HBEAT in ${HBEATS[@]}
do
    IFS=':' read -ra INFO <<< "$HBEAT"

    NUM=""
    HOST=""
    HB_PORT="9694"
    HB_DEV=""

    [[ "${INFO[0]}" != "" ]] && NUM="${INFO[0]}"
    [[ "${INFO[1]}" != "" ]] && HOST="${INFO[1]}"
    [[ "${INFO[2]}" != "" ]] && HB_PORT="${INFO[2]}"

    echo "
heartbeat_destination$NUM = '$HOST'
heartbeat_destination_port$NUM = $HB_PORT
" >> $CONFIG_FILE
done
echo "Adding other pgpools in config"
IFS=',' read -ra OTHERS <<< "$PGP_OTHERS"
for OTHER in ${OTHERS[@]}
do
    IFS=':' read -ra INFO <<< "$OTHER"

    NUM=""
    HOST=""
    PGP_PORT="9999"
    WD_PORT=9000

    [[ "${INFO[0]}" != "" ]] && NUM="${INFO[0]}"
    [[ "${INFO[1]}" != "" ]] && HOST="${INFO[1]}"
    [[ "${INFO[2]}" != "" ]] && PGP_PORT="${INFO[2]}"
    [[ "${INFO[3]}" != "" ]] && WD_PORT="${INFO[3]}"

    echo "
other_pgpool_hostname$NUM = '$HOST'
other_pgpool_port$NUM = $PGP_PORT
other_wd_port$NUM = $WD_PORT
" >> $CONFIG_FILE
done
cat <<EOF >> $CONFIG_FILE
#------------------------------------------------------------------------------
# OTHERS
#------------------------------------------------------------------------------
relcache_expire = 0
                                   # Life time of relation cache in seconds.
                                   # 0 means no cache expiration(the default).
                                   # The relation cache is used for cache the
                                   # query result against PostgreSQL system
                                   # catalog to obtain various information
                                   # including table structures or if it's a
                                   # temporary table or not. The cache is
                                   # maintained in a pgpool child local memory
                                   # and being kept as long as it survives.
                                   # If someone modify the table by using
                                   # ALTER TABLE or some such, the relcache is
                                   # not consistent anymore.
                                   # For this purpose, cache_expiration
                                   # controls the life time of the cache.
relcache_size = 256
                                   # Number of relation cache
                                   # entry. If you see frequently:
                                                                   # "pool_search_relcache: cache replacement happend"
                                                                   # in the pgpool log, you might want to increate this number.

check_temp_table = on
                                   # If on, enable temporary table check in SELECT statements.
                                   # This initiates queries against system catalog of primary/master
                                                                   # thus increases load of master.
                                                                   # If you are absolutely sure that your system never uses temporary tables
                                                                   # and you want to save access to primary/master, you could turn this off.
                                                                   # Default is on.

check_unlogged_table = on
                                   # If on, enable unlogged table check in SELECT statements.
                                   # This initiates queries against system catalog of primary/master
                                   # thus increases load of master.
                                   # If you are absolutely sure that your system never uses unlogged tables
                                   # and you want to save access to primary/master, you could turn this off.
                                   # Default is on.
#------------------------------------------------------------------------------
# IN MEMORY QUERY MEMORY CACHE
#------------------------------------------------------------------------------
memory_cache_enabled = off
EOF

rm -f /var/run/pgpool/pgpool.pid /var/run/pgpool/.s.PGSQL.9999 /var/run/pgpool/.s.PGSQL.9898 2>/dev/null
log_info "inject env variables into config file"
injectConfigsFromEnv
log_info "Start pgpool in foreground"
exec /usr/bin/pgpool -n -f ${CONFIG_FILE} -F $PCP_FILE -a $HBA_FILE
