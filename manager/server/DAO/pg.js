const SQL_ACTIVITY_STAT = 'select * from pg_stat_activity;';
const SQL_REPL_NODES = 'select * from nodes;';
const SQL_SHOW_POOL_NODES = 'show pool_nodes;';
const pgppool = require('../config/pgppool').pool;
const { pools } = require('../config/pgpool');
const { getStats, isInRecovery } = require('./replication.js');

const getStatActivity = () => {
  const q = new Promise((resolve, reject) => {
    pgppool.query(SQL_ACTIVITY_STAT, [], (error, result) => {
      if (error) {
        reject(error);
      } else {
        resolve(result);
      }
    });
  });
  return q;
};

const getReplNodesFromDB = async db =>
  new Promise((resolve, reject) => {
    db.query(SQL_REPL_NODES, [], (error, result) => {
      if (error) {
        reject(error);
      } else {
        resolve(result);
      }
    });
  });

const getReplNodes = async () => {
  try {
    const result = await getReplNodesFromDB(pgppool);
    return Promise.resolve(result);
  } catch (e) {
    return Promise.reject('Cannot connect to pgpool');
    /*
    let pools = require("../config/pgpool").pools;
    let result;
    for (var i = 0; i < pools.length && ! result; i++) {
      try {
        result = await getReplNodesFromDB(pools[i].pool);
        return Promise.resolve(result);
      } catch (e) {
        console.log(`cannot connect to ${pools[i].host}`);
      }
    }
    */
  }
};

const getPoolNodes = () => {
  const q = new Promise((resolve, reject) => {
    pgppool
      .connect()
      .then((client) => {
        client
          .query(SQL_SHOW_POOL_NODES)
          .then((res) => {
            client.release();
            resolve(res);
          })
          .catch((err) => {
            client.release();
            reject(err);
          });
      })
      .catch((err) => {
        console.log('pool connect error', err);
        reject(err);
      });
  });
  return q;
};

const dbStates = () => {
  const states = [];
  return new Promise((resolve) => {
    pools.forEach((el, idx) => {
      const state = { idx, host: el.host };
      isInRecovery(el.host)
        .then((inRecovery) => {
          states.push({
            idx, host: el.host, status: 'green', in_recovery: inRecovery,
          });
          if (states.length === pools.length) {
            return resolve(states);
          }
        })
        .catch(() => {
          states.push({
            idx, host: el.host, status: 'red',
          });
          if (states.length === pools.length) {
            return resolve(states);
          }
        });
    });
  });
};

const replicationStats = () => getStats();

module.exports = {
  getStatActivity,
  getReplNodes,
  getPoolNodes,
  dbStates,
  replicationStats,
};
