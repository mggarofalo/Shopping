#!/bin/bash

set -euo pipefail

if [[ "$#" -ne 4 ]]; then
    echo "usage: $0 <result.xcresult> <baseline.json> <report.json> <summary.md>" >&2
    exit 2
fi

result_bundle="$1"
baseline_path="$2"
report_path="$3"
summary_path="$4"
raw_report="${report_path%.json}.raw.json"

if [[ ! -d "$result_bundle" ]]; then
    echo "coverage result bundle not found: $result_bundle" >&2
    exit 1
fi

xcrun xccov view --report --json "$result_bundle" > "$raw_report"

jq -n \
    --slurpfile baseline "$baseline_path" \
    --slurpfile coverage "$raw_report" '
    def ratio($covered; $total): if $total == 0 then 1 else $covered / $total end;
    $baseline[0] as $baseline |
    ($coverage[0].targets[] | select(.name == $baseline.target)) as $target |
    ([ $target.files[].functions[] ] | length) as $functionCount |
    ([ $target.files[].functions[] | select(.executionCount > 0) ] | length) as $coveredFunctions |
    {
      target: $target.name,
      lineCoverage: $target.lineCoverage,
      coveredLines: $target.coveredLines,
      executableLines: $target.executableLines,
      functionCoverage: ratio($coveredFunctions; $functionCount),
      coveredFunctions: $coveredFunctions,
      functions: $functionCount,
      tolerance: $baseline.materialRegressionTolerance,
      scopes: [
        $baseline.scopes[] as $scope |
        ([ $scope.files[] as $configuredFile |
          [ $target.files[] | select(.name == $configuredFile) ] |
          {
            name: $configuredFile,
            matches: length,
            coveredLines: (map(.coveredLines) | add // 0),
            executableLines: (map(.executableLines) | add // 0)
          }
        ]) as $files |
          ($files | map(.coveredLines) | add // 0) as $covered |
          ($files | map(.executableLines) | add // 0) as $total |
          ($files | all(.matches == 1 and .executableLines > 0)) as $configurationPassed |
          {
            name: $scope.name,
            lineCoverage: ratio($covered; $total),
            coveredLines: $covered,
            executableLines: $total,
            configurationPassed: $configurationPassed,
            invalidFiles: [$files[] | select(.matches != 1 or .executableLines == 0) | .name],
            baselineLineCoverage: $scope.lineCoverage,
            passed: ($configurationPassed and
              ratio($covered; $total) + $baseline.materialRegressionTolerance >= $scope.lineCoverage)
          }
      ],
      baselineLineCoverage: $baseline.lineCoverage,
      baselineFunctionCoverage: $baseline.functionCoverage
    } |
    .linePassed = (.lineCoverage + .tolerance >= .baselineLineCoverage) |
    .functionPassed = (.functionCoverage + .tolerance >= .baselineFunctionCoverage) |
    .passed = (.linePassed and .functionPassed and ([.scopes[].passed] | all))
    ' > "$report_path"

jq -r '
    "## Code coverage\n\n" +
    "| Scope | Lines | Functions | Baseline | Result |\n" +
    "| --- | ---: | ---: | ---: | --- |\n" +
    "| `" + .target + "` | " + ((.lineCoverage * 10000 | round) / 100 | tostring) + "% | " +
      ((.functionCoverage * 10000 | round) / 100 | tostring) + "% | " +
      ((.baselineLineCoverage * 10000 | round) / 100 | tostring) + "% lines | " +
      (if .linePassed and .functionPassed then "Pass" else "Fail" end) + " |\n" +
    ([.scopes[] |
      "| " + .name + " | " + ((.lineCoverage * 10000 | round) / 100 | tostring) +
      "% | — | " + ((.baselineLineCoverage * 10000 | round) / 100 | tostring) +
      "% lines | " + (if .passed then "Pass" else "Fail" end) + " |"
    ] | join("\n")) + "\n\n" +
    "A regression larger than " + ((.tolerance * 10000 | round) / 100 | tostring) +
    " percentage points fails the gate."
    ' "$report_path" > "$summary_path"

cat "$summary_path"
jq -e '.passed' "$report_path" > /dev/null
