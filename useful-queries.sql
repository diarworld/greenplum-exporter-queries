-- segments status with replication
SELECT
  sc.content,
  sc.dbid,
  sc.address,
  sc.port,
  sc.datadir as datadir,
  CASE WHEN (sc.role = sc.preferred_role) THEN true ELSE false END as balanced,
  sc.status = 'u' as up,
  (sc.role='p' and sc.status = 'u') or COALESCE(r.sync_state, '') = 'sync' as synced,
  CASE 
    WHEN sc.role='m' THEN COALESCE(r.state, '') = 'streaming' 
    ELSE db.valid 
  END as valid,
  pg_size_pretty(pg_xlog_location_diff(sent_location, write_location)) as write_delay,
  pg_size_pretty(pg_xlog_location_diff(sent_location, flush_location)) as flush_delay,
  pg_size_pretty(pg_xlog_location_diff(sent_location, replay_location)) as replay_delay
FROM gp_segment_configuration sc
 join gp_pgdatabase db on db.dbid=sc.dbid
 left outer join gp_stat_replication r on 
                    r.gp_segment_id = sc.content and 
                    r.application_name='gp_walreceiver';

-- pg_stat_activity with user description and roles, locks as blocking_pids, spillfiles and spillsize
CREATE OR REPLACE VIEW public.active_queries
AS SELECT psa.usename,
    pr.memberof,
    pr.description,
    psa.pid,
    psa.query_start,
    psa.query,
    psa.rsgname,
    blocks.blocking_pids,
    spills.spillsize,
    spills.spillfiles,
    psa.state
   FROM ( SELECT pg_stat_activity.usename,
            pg_stat_activity.pid,
            pg_stat_activity.sess_id,
            pg_stat_activity.query_start,
            pg_stat_activity.query,
            pg_stat_activity.state_change,
            pg_stat_activity.state,
            pg_stat_activity.waiting,
            pg_stat_activity.waiting_reason,
            pg_stat_activity.rsgname
           FROM pg_stat_activity) psa
     LEFT JOIN ( SELECT r.rolname,
            r.rolsuper,
            ARRAY( SELECT b.rolname
                   FROM pg_auth_members m
                     JOIN pg_roles b ON m.roleid = b.oid
                  WHERE m.member = r.oid) AS memberof,
            shobj_description(r.oid, 'pg_authid'::name) AS description
           FROM pg_roles r) pr ON psa.usename = pr.rolname
     LEFT JOIN ( SELECT ngl.pid AS blocked_pid,
            string_agg(gl.pid::text, ','::text) AS blocking_pids
           FROM pg_locks ngl
             JOIN pg_locks gl ON gl.database = ngl.database AND gl.relation = ngl.relation
          WHERE NOT ngl.granted AND gl.granted AND (gl.pid IN ( SELECT pg_stat_activity.pid
                   FROM pg_stat_activity))
          GROUP BY ngl.pid) blocks ON psa.pid = blocks.blocked_pid
     LEFT JOIN ( SELECT gp_workfile_usage_per_query.pid,
            sum(gp_workfile_usage_per_query.size) AS spillsize,
            sum(gp_workfile_usage_per_query.numfiles) AS spillfiles
           FROM gp_toolkit.gp_workfile_usage_per_query
          GROUP BY gp_workfile_usage_per_query.pid) spills ON psa.pid = spills.pid
  ORDER BY psa.query_start;
  
  -- all locks
CREATE OR REPLACE VIEW public.locks_monitoring
AS SELECT blocked_locks.pid AS blocked_pid,
    blocked_activity.usename AS blocked_user,
    blocking_locks.pid AS blocking_pid,
    blocking_activity.usename AS blocking_user,
    blocked_activity.query AS blocked_statement,
    blocking_activity.query AS current_statement_in_blocking_process
   FROM pg_locks blocked_locks
     JOIN pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
     JOIN pg_locks blocking_locks ON blocking_locks.locktype = blocked_locks.locktype AND NOT blocking_locks.database IS DISTINCT FROM blocked_locks.database AND NOT blocking_locks.relation IS DISTINCT FROM blocked_locks.relation AND NOT blocking_locks.page IS DISTINCT FROM blocked_locks.page AND NOT blocking_locks.tuple IS DISTINCT FROM blocked_locks.tuple AND NOT blocking_locks.virtualxid IS DISTINCT FROM blocked_locks.virtualxid AND NOT blocking_locks.transactionid IS DISTINCT FROM blocked_locks.transactionid AND NOT blocking_locks.classid IS DISTINCT FROM blocked_locks.classid AND NOT blocking_locks.objid IS DISTINCT FROM blocked_locks.objid AND NOT blocking_locks.objsubid IS DISTINCT FROM blocked_locks.objsubid AND blocking_locks.pid <> blocked_locks.pid
     JOIN pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
  WHERE NOT blocked_locks.granted;
