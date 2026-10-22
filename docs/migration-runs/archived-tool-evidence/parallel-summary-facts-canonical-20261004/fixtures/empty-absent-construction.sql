CREATE TABLE trace_range (start_ts INTEGER, end_ts INTEGER);
INSERT INTO trace_range VALUES (1000,1001);
CREATE TABLE process (ipid INTEGER,pid INTEGER,name TEXT,start_ts INTEGER);
CREATE TABLE thread (itid INTEGER,tid INTEGER,name TEXT,start_ts INTEGER,ipid INTEGER);

        CREATE TABLE sched_slice (
            id INTEGER, ts INTEGER, dur INTEGER, cpu INTEGER, itid INTEGER, ipid INTEGER
        );
        CREATE TABLE thread_state (
            id INTEGER, ts INTEGER, dur INTEGER, cpu INTEGER, itid INTEGER, state TEXT
        );
        CREATE TABLE callstack (
            id INTEGER, ts INTEGER, dur INTEGER, callid INTEGER, name TEXT
        );
        