#!/bin/bash

echo "Exec ip with params $@ at `date`"
if [ -z $DOCKERHOST ] ; then
  /usr/sbin/ip $@
else
  # we are in a swarm cluster
  ssh postgres@${DOCKERHOST} -C "/usr/sbin/ip $@"
fi
exit $?
