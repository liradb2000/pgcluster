#!/bin/bash

#put keys on the remote AND on the local server

LOGFILE=/var/log/pg/follow_master.log
if [ ! -f $LOGFILE ] ; then
 > $LOGFILE
fi
echo "executing follow_master.sh at `date` on `hostname`"  | tee -a $LOGFILE

NODEID=$1
HOSTNAME=$2
NEW_MASTER_ID=$3
PORT_NUMBER=$4
NEW_MASTER_HOST=$5
OLD_MASTER_ID=$6
OLD_PRIMARY_ID=$7
PGDATA=${PGDATA:-/data}
PGVER=${PGVER:-11}

echo NODEID=${NODEID} 
echo HOSTNAME=${HOSTNAME}
echo NEW_MASTER_ID=${NEW_MASTER_ID}
echo PORT_NUMBER=${PORT_NUMBER}
echo NEW_MASTER_HOST=${NEW_MASTER_HOST}
echo OLD_MASTER_ID=${OLD_MASTER_ID}
echo OLD_PRIMARY_ID=${OLD_PRIMARY_ID}
echo PGDATA=${PGDATA}
pcp_node_info -h localhost -p 9898 -w $NODEID | tee -a $LOGFILE
if [ $NODEID -eq $OLD_PRIMARY_ID ] ; then
  echo "Do nothing as this is the failed master. We could prevent failed master to restart here, so that we can investigate the issue" | tee -a $LOGFILE
else
  ssh_options="ssh -p 222 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
  #set -x
  in_reco=$( $ssh_options postgres@${HOSTNAME} 'psql -t -c "select pg_is_in_recovery();"' | head -1 | awk '{print $1}' )
  if [ "a${in_reco}" != "at" ] ; then
    echo "Node $HOSTNAME is not in recovery, probably a degenerated master, skip it" | tee -a $LOGFILE
    exit 0
  fi
  $ssh_options postgres@${HOSTNAME} "/usr/pgsql-${PGVER}/bin/repmgr --log-to-file -f /etc/repmgr/${PGVER}/repmgr.conf -h ${NEW_MASTER_HOST} -D ${PGDATA} -U repmgr -d repmgr standby follow -v"
  echo "Sleep 10"
  sleep 10
  echo "Attach node ${NODEID}"
  pcp_attach_node -h localhost -p 9898 -w ${NODEID}
fi
echo "Done follow_master.sh at `date`"  | tee -a $LOGFILE
