#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${SLACK_WEBHOOK_URL}" ]]; then
    echo "::error::The internal-slack environment is missing SLACK_CI_WEBHOOK_URL"
    exit 1
fi

github_api() {
    curl \
        --fail-with-body \
        --silent \
        --show-error \
        --max-time 15 \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GH_TOKEN}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$1"
}

jobs_url="${API_URL}/repos/${REPOSITORY}/actions/runs/${RUN_ID}/jobs?filter=latest&per_page=100"
if ! jobs_json="$(github_api "${jobs_url}")"; then
    jobs_json='{"jobs":[]}'
fi

failed_jobs="$(
    jq -c \
        '[.jobs[] | select(.conclusion == "failure")] as $all |
         [$all[] | select(.name != "space-ci")] as $concrete |
         if ($concrete | length) > 0 then $concrete else $all end' \
        <<<"${jobs_json}"
)"
failed_jobs_total="$(jq 'length' <<<"${failed_jobs}")"
failures="$(
    jq -c '[.[:8][] | {job: .name, url: .html_url}]' <<<"${failed_jobs}"
)"

if [[ "$(jq 'length' <<<"${failures}")" == 0 ]]; then
    failures="$(
        jq -nc \
            --arg url "${RUN_URL}" \
            '[{"job":"Failed run details","url":$url}]'
    )"
elif ((failed_jobs_total > 8)); then
    failures="$(
        jq -c \
            --arg job "$((failed_jobs_total - 8)) additional failed job(s)" \
            --arg url "${RUN_URL}" \
            '. + [{job: $job, url: $url}]' \
            <<<"${failures}"
    )"
fi

pulls_url="${API_URL}/repos/${REPOSITORY}/commits/${COMMIT_SHA}/pulls?per_page=100"
if ! pulls_json="$(github_api "${pulls_url}")"; then
    pulls_json='[]'
fi
pr="$(
    jq -c \
        '[.[] | select(.merged_at != null and .base.ref == "main")] |
         sort_by(.merged_at) | last // {}' \
        <<<"${pulls_json}"
)"
pr_url="$(jq -r '.html_url // empty' <<<"${pr}")"
pr_number="$(jq -r '.number // empty' <<<"${pr}")"

commit_description="${COMMIT_DESCRIPTION%%$'\n'*}"
commit_description="${commit_description:0:300}"
payload="$(
    jq -n \
        --arg url "${RUN_URL}" \
        --arg sha "${COMMIT_SHA:0:12}" \
        --arg commit_url "${COMMIT_URL}" \
        --arg author "${COMMIT_AUTHOR}" \
        --arg description "${commit_description}" \
        --arg pr_url "${pr_url}" \
        --arg pr_number "${pr_number}" \
        --argjson failures "${failures}" \
        'def slack_escape:
           gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
         {
          text: (
            ":x: *OSS SPACE main CI failed*\n" +
            "*Commit:* <" + $commit_url + "|`" + $sha + "`> — " +
            ($description | slack_escape) + "\n" +
            (if $pr_url == "" then ""
             else "*PR:* <" + $pr_url + "|#" + $pr_number + ">\n" end) +
            "*Author:* " + ($author | slack_escape) + "\n" +
            "*Failures:*\n" +
            ($failures | map(
              "• *<" + .url + "|" + (.job | slack_escape) + ">*"
            ) | join("\n")) + "\n" +
            "<" + $url + "|Open failed run>"
          )
        }'
)"

curl \
    --fail-with-body \
    --silent \
    --show-error \
    --max-time 15 \
    -H "Content-Type: application/json" \
    --data-binary "${payload}" \
    "${SLACK_WEBHOOK_URL}"
