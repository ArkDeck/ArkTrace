def exact_keys($expected): (keys | sort) == ($expected | sort);
def empty_filters: {
  cpu:null, processKey:null, pid:null, threadKey:null, tid:null,
  rawState:null, normalizedState:null, name:null, nameMatch:"exact",
  minimumDurationNs:null, depth:null, counterFilterID:null
};

.contextWorkload as $context
| .analysisWorkload as $analysis
| ($context | exact_keys([
    "name", "time", "normalizedRange", "filters", "maximumEvents",
    "maximumRows", "maximumOutputBytes", "timeoutSeconds", "timeoutAttoseconds"
  ]))
and $context.name == "timestamp-default-v1"
and $context.time == {
  timestampNs:10200000000, windowBeforeNs:50000000, windowAfterNs:50000000
}
and $context.normalizedRange == {startNs:10150000000, endNs:10250000000}
and $context.filters == empty_filters
and $context.maximumEvents == 10000
and $context.maximumRows == 10000
and $context.maximumOutputBytes == 8388608
and $context.timeoutSeconds == 30
and $context.timeoutAttoseconds == 0
and ($analysis | exact_keys(["name", "range", "globalMaximumRows", "parameters"]))
and $analysis.name == "agent-range-default-v1"
and $analysis.range == {startNs:10100000000, endNs:10300000000}
and $analysis.globalMaximumRows == 10000
and ($analysis.parameters
  | exact_keys([
      "filters", "maximumCPUSlices", "maximumProcessSlices",
      "maximumThreadSlices", "maximumStateIntervals", "maximumNamedSlices",
      "maximumSchedulingEvents", "maximumHotEvents", "topProcessLimit",
      "topThreadLimit", "longSliceLimit", "schedulingSampleLimit",
      "hotIntervalLimit", "hotBucketCount", "minimumLongSliceDurationNs",
      "timeoutSeconds", "timeoutAttoseconds"
    ]))
and $analysis.parameters.filters == empty_filters
and ([
  $analysis.parameters.maximumCPUSlices,
  $analysis.parameters.maximumProcessSlices,
  $analysis.parameters.maximumThreadSlices,
  $analysis.parameters.maximumStateIntervals,
  $analysis.parameters.maximumNamedSlices,
  $analysis.parameters.maximumSchedulingEvents,
  $analysis.parameters.maximumHotEvents
] | all(. == 10000))
and ([
  $analysis.parameters.topProcessLimit,
  $analysis.parameters.topThreadLimit,
  $analysis.parameters.longSliceLimit,
  $analysis.parameters.schedulingSampleLimit,
  $analysis.parameters.hotIntervalLimit
] | all(. == 1000))
and $analysis.parameters.hotBucketCount == 100
and $analysis.parameters.minimumLongSliceDurationNs == 0
and $analysis.parameters.timeoutSeconds == 30
and $analysis.parameters.timeoutAttoseconds == 0
