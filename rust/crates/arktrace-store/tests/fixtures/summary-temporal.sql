
                CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
                INSERT INTO trace_range VALUES (1000, 2000);
                CREATE TABLE process (
                    ipid INTEGER, pid INTEGER, name TEXT, start_ts INTEGER, end_ts INTEGER
                );
                INSERT INTO process VALUES (1, 100, 'old', 1050, 1200);
                INSERT INTO process VALUES (2, 101, 'active', 1200, NULL);
                INSERT INTO process VALUES (3, 102, 'future', 1500, 1900);
                INSERT INTO process VALUES (4, 103, 'unknown-lifetime', NULL, NULL);
                INSERT INTO process VALUES (5, 104, 'invalid-lifetime', 1500, 1400);
                CREATE TABLE thread (
                    itid INTEGER, tid INTEGER, name TEXT, start_ts INTEGER,
                    end_ts INTEGER, ipid INTEGER
                );
                INSERT INTO thread VALUES (1, 100, 'old', 1050, 1200, 1);
                INSERT INTO thread VALUES (2, 101, 'active', 1200, NULL, 2);
                INSERT INTO thread VALUES (3, 102, 'future', 1500, 1900, 3);
                INSERT INTO thread VALUES (4, 103, 'unknown-lifetime', NULL, NULL, 4);
                INSERT INTO thread VALUES (5, 104, 'invalid-lifetime', 1500, 1400, 2);
                CREATE TABLE sched_slice (
                    id INTEGER, ts INTEGER, dur INTEGER, cpu INTEGER,
                    itid INTEGER, ipid INTEGER
                );
                INSERT INTO sched_slice VALUES (1, 1100, 100, 0, 1, 1);
                INSERT INTO sched_slice VALUES (2, 1200, 0, 1, 2, 2);
                INSERT INTO sched_slice VALUES (3, 1250, -1, 2, 2, 2);
                INSERT INTO sched_slice VALUES (4, 1400, 100, 3, 2, 2);
                CREATE TABLE thread_state (
                    id INTEGER, ts INTEGER, dur INTEGER, cpu INTEGER,
                    itid INTEGER, state TEXT
                );
                INSERT INTO thread_state VALUES (1, 1100, 100, 0, 1, 'S');
                INSERT INTO thread_state VALUES (2, 1200, 0, 1, 2, 'R');
                INSERT INTO thread_state VALUES (3, 1300, 50, 2, 2, 'Running');
                CREATE TABLE callstack (
                    id INTEGER, ts INTEGER, dur INTEGER, callid INTEGER, name TEXT
                );
                INSERT INTO callstack VALUES (1, 1100, 100, 1, 'old');
                INSERT INTO callstack VALUES (2, 1200, 200, 2, 'inside');
                INSERT INTO callstack VALUES (3, 1400, 0, 3, 'right-boundary');
                
        CREATE INDEX arktrace_v3_sched_slice_cpu_ts_dur
            ON sched_slice(cpu, ts, dur);
        CREATE INDEX arktrace_v3_thread_state_itid_ts_dur
            ON thread_state(itid, ts, dur);
        CREATE INDEX arktrace_v3_callstack_callid_ts_dur
            ON callstack(callid, ts, dur);
        
                CREATE TABLE measure (ts INTEGER, value INTEGER, filter_id INTEGER);
                CREATE TABLE cpu_measure_filter (id INTEGER, name TEXT, cpu INTEGER);
                CREATE TABLE process_measure_filter (id INTEGER, name TEXT, ipid INTEGER);
                INSERT INTO cpu_measure_filter VALUES (1, 'cpu', 0);
                INSERT INTO process_measure_filter VALUES (2, 'process', 2);
                INSERT INTO measure VALUES (1200, 1, 1);
                INSERT INTO measure VALUES (1400, 1, 2);
                CREATE TABLE stat (
                    event_name TEXT, stat_type TEXT, count INTEGER,
                    serverity TEXT, source TEXT
                );
                INSERT INTO stat VALUES ('a', 'received', 2, 'info', 'trace');
                INSERT INTO stat VALUES ('b', 'received', 3, 'info', 'trace');
                INSERT INTO stat VALUES ('c', 'received', 4, 'info', 'ftrace');
                INSERT INTO stat VALUES ('broken', 'invalid_data', 2, 'warn', 'trace');
                INSERT INTO stat VALUES ('negative', 'received', -5, 'warn', 'trace');
                
                
INSERT INTO process VALUES (6, 106, 'final-instant', 2000, 2000);
INSERT INTO thread VALUES (6, 106, 'final-instant', 2000, 2000, 6);
INSERT INTO sched_slice VALUES (5, 2000, 0, 4, 6, 6);
INSERT INTO thread_state VALUES (4, 2000, 0, 4, 6, 'R');
INSERT INTO callstack VALUES (4, 2000, 0, 6, 'final-instant');
INSERT INTO measure VALUES (2000, 2, 1);
