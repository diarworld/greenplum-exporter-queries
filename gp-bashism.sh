#!/usr/bin/env bash
#
# Shell script to kill active of idle queries in GP.
# Requirements: psql, curl
#
# Copyright 2020, Dmitry Ibragimov
#   Author: Dmitry Ibragimov <http://github.com/diarworld>
#
# SPDX-License-Identifier: MIT
#
# This program is free software. You can use it and/or modify it under the
# terms of the MIT License.
#

# ATTENTION! Create terminated_queries table on gpperfmon database before first run:
# CREATE TABLE public.terminated_queries (
# 	reason text NULL,
# 	usename name NULL,
# 	application_name text NULL,
# 	client_addr inet NULL,
# 	query text NULL,
# 	query_start timestamptz NULL,
# 	query_killed timestamptz NULL,
# 	terminated bool NULL
# )
# DISTRIBUTED RANDOMLY;

set -e

source /home/gpadmin/.bashrc;


### VARIABLES

SCRIPT_NAME=$(basename "$0")

#Place here you slack webhook URL if you want to receive alerts
# SLACK_WEBHOOKURL="https://hooks.slack.com/services/URL"
# SLACK_CHANNEL="@test"


DATE=$(date '+%Y-%m-%d')

STARTALL=$SECONDS

### CHECK IF SCRIPT IS ALREADY RUNNING

RUNNING=$(ps -ef | grep -c "$SCRIPT_NAME")

if [ "${RUNNING}" -gt 3 ]; then
    echo -e "$(date '+%Y%m%d:%H:%m:%S:%6N') $SCRIPT_NAME:$HOSTNAME:$USER-[ERROR]:-The $SCRIPT_NAME script was already running. Exiting."
    if [ -n "$SLACK_WEBHOOKURL" ]; then curl -X POST --data-urlencode "payload={\"channel\": \"$SLACK_CHANNEL\", \"username\": \"webhookbot\", \"text\": \"[ERROR] Duplicate run ($RUNNING) for $SCRIPT_NAME. Possibly need to change cron.\", \"icon_emoji\": \":ghost:\"}" "$SLACK_WEBHOOKURL"; fi
    exit 0
fi

###MAIN SCRIPT

echo "$(date '+%Y%m%d:%H:%m:%S:%6N') $SCRIPT_NAME:$HOSTNAME:$USER-[INFO]:-Start killing queries..."

# Note if you have no installed gpperfmon extension, delete last query (cause, you have no queries_now table).
psql -d gpperfmon << EOF 
INSERT into terminated_queries
SELECT 'active'::text as reason, usename, application_name, client_addr, query, query_start, now() as query_killed, pg_terminate_backend(pid, 'query duration > 60 min') as terminated
FROM pg_catalog.pg_stat_activity
WHERE state = 'active'
AND usename not in ('gpadmin')
AND query_start < (now() - INTERVAL '60 min')::timestamp
AND waiting = false;

INSERT into terminated_queries
SELECT 'idle'::text as reason, usename, application_name, client_addr, query, query_start, now() as query_killed, pg_terminate_backend(pid, 'idle connection > 120 min') as terminated
FROM pg_catalog.pg_stat_activity
WHERE state = 'idle'
AND usename not in ('gpadmin')
AND query_start < (now() - INTERVAL '120 min')::timestamp
AND waiting = false;

INSERT into terminated_queries
SELECT 'idle in transaction'::text as reason, usename, application_name, client_addr, query, query_start, now() as query_killed, pg_terminate_backend(pid, 'idle in transaction > 10 min') as terminated
FROM pg_catalog.pg_stat_activity
WHERE state = 'idle in transaction'
AND usename not in ('gpadmin')
AND query_start < (now() - INTERVAL '10 min')::timestamp
AND waiting = false;

INSERT into terminated_queries
with full_queries as (
        SELECT username, query_text, max(ssid) as max_ssid, count(1) as queries_count
        FROM public.queries_now WHERE username not like '%bot'
        AND username not in ('gpadmin')
        AND status = 'start'
        AND query_text != 'Query text unavailable'
        group by 1,2
)
SELECT 'duplicate'::text as reason, usename, application_name, client_addr, full_queries.query_text as query, query_start, now() as query_killed, pg_terminate_backend(pid, 'duplicate queries runs > 2 min') as terminated
FROM full_queries
LEFT JOIN pg_stat_activity psa on psa.sess_id = full_queries.max_ssid
WHERE state = 'active'
AND queries_count > 1
AND query_start < (now() - INTERVAL '2 min')::timestamp
AND waiting = false;
EOF


DURATIONALL=$(( SECONDS - STARTALL ))

echo "$(date '+%Y%m%d:%H:%m:%S:%6N') $SCRIPT_NAME:$HOSTNAME:$USER-[INFO]:-All queries processed sucessfully for $DURATIONALL seconds"

exit 0
