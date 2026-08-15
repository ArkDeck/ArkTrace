.formatVersion == 1
and ((keys | sort) == [
  "acquisitionRecordSHA256",
  "formatVersion",
  "integrityReportSHA256",
  "redistributionGrantSHA256",
  "reviewedAt",
  "reviewer",
  "traceByteCount",
  "traceSHA256"
])
and .traceSHA256 == $traceSHA
and (.traceByteCount | tostring) == $traceBytes
and .acquisitionRecordSHA256 == $acquisitionSHA
and .integrityReportSHA256 == $integritySHA
and .redistributionGrantSHA256 == $grantSHA
and (.reviewer | type == "string" and length > 0 and length <= 256)
and (.reviewedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
