def index_names($plan):
  [$plan[]
   | try capture("^SEARCH [A-Za-z0-9_]+ USING COVERING INDEX (?<index>[A-Za-z0-9_]+)(?: .*)?$").index catch empty];

def all_table_accesses_use_reviewed_indexes($plan):
  [$plan[] | select(test("^(SCAN|SEARCH)( |$)"))
   | test("^SEARCH [A-Za-z0-9_]+ USING COVERING INDEX [A-Za-z0-9_]+(?: |$)")]
  | all;

def exact_detail($name; $eventIndexes):
  (.diagnostics.queryPlans[$name]) as $plan
  | (index_names($plan)) as $indexes
  | all_table_accesses_use_reviewed_indexes(.diagnostics.queryPlans[$name])
  and ($plan | length) == 3
  and ($indexes | length) == 3
  and ([$indexes[] | select(. == "arktrace_v2_process_ipid_pid_name")] | length) == 1
  and ([$indexes[] | select(. == "arktrace_v2_thread_itid_tid_name_ipid")] | length) == 1
  and ([$indexes[] as $candidate
      | select($eventIndexes | index($candidate) != null)] | length) == 1
  and ([$indexes[] as $candidate | select(
      $candidate != "arktrace_v2_process_ipid_pid_name"
      and $candidate != "arktrace_v2_thread_itid_tid_name_ipid"
      and ($eventIndexes | index($candidate) == null)
  )] | length) == 0;

def exact_density($name; $eventIndexes):
  (.diagnostics.queryPlans[$name]) as $plan
  | (index_names($plan)) as $indexes
  | all_table_accesses_use_reviewed_indexes(.diagnostics.queryPlans[$name])
  and ($plan | length) == 2
  and $plan[1] == "USE TEMP B-TREE FOR GROUP BY"
  and ($indexes | length) == 1
  and ($eventIndexes | index($indexes[0]) != null);

exact_detail("viewport.cpu.detail"; [
  "arktrace_v2_sched_slice_cpu_ts_id_dur_itid",
  "arktrace_v2_sched_slice_cpu_ts_cover_optional"
])
and exact_detail("viewport.threadState.detail"; [
  "arktrace_v2_thread_state_itid_ts_id_dur",
  "arktrace_v2_thread_state_itid_ts_cover_cpu"
])
and exact_detail("viewport.namedSlice.detail"; [
  "arktrace_v2_callstack_callid_ts_id_dur",
  "arktrace_v2_callstack_callid_ts_cover_optional"
])
and exact_density("viewport.cpu.density"; [
  "arktrace_v3_sched_slice_cpu_ts_dur"
])
and exact_density("viewport.threadState.density"; [
  "arktrace_v3_thread_state_itid_ts_dur"
])
and exact_density("viewport.namedSlice.density"; [
  "arktrace_v3_callstack_callid_ts_dur"
])
