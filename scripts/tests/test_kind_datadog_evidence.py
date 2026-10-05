"""Evidence cannot overwrite a run or query across experiment boundaries."""

import importlib.util
import json
import sys

import pytest
from kind_chart_render import KIND_DIR

sys.path.insert(0, str(KIND_DIR / "scripts"))
spec = importlib.util.spec_from_file_location(
    "kind_datadog_evidence",
    KIND_DIR.parents[2] / "scripts/tests/observability/datadog_evidence.py",
)
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


def test_scoped_window_preserves_source_and_never_claims_ingestion(
    tmp_path, monkeypatch
):
    config = {
        "backend": "saas",
        "environment": "local-kind-owner-box",
        "version": "abc-after-datadog",
        "site": "datadoghq.com",
    }
    monkeypatch.setattr(
        evidence, "snapshot", lambda _c: {"identities": {"cluster": "same-cluster"}}
    )
    monkeypatch.setattr(evidence, "git", lambda *_a: "source-revision")
    clock = iter(["2026-09-22T10:00:00+00:00", "2026-09-22T10:05:00+00:00"])
    monkeypatch.setattr(evidence, "now", lambda: next(clock))
    output = tmp_path / "run"
    manifest = evidence.begin(output, config)
    assert not manifest["backend_ingestion_verified"]
    assert manifest["checkout_sha"] == "source-revision"
    with pytest.raises(ValueError, match="overwrite"):
        evidence.begin(output, config)
    with pytest.raises(ValueError, match="Configuration changed"):
        evidence.finish(output, {**config, "version": "abc-after-otel"})
    result = evidence.finish(output, config)
    assert result["from"] == "2026-09-22T10:00:00+00:00"
    assert result["to"] == "2026-09-22T10:05:00+00:00"
    for query in list(result["metric_queries"].values()) + [
        result["log_query"],
        result["span_query"],
    ]:
        assert "env:local-kind-owner-box" in query
        assert "version:abc-after-datadog" in query
    assert "query-plan-only" in result["status"]
    with pytest.raises(ValueError, match="overwrite"):
        evidence.finish(output, config)
    assert json.loads((output / "manifest.json").read_text()) == manifest


def test_cluster_reset_invalidates_comparison(tmp_path, monkeypatch):
    config = {"backend": "saas"}
    monkeypatch.setattr(
        evidence, "snapshot", lambda _c: {"identities": {"cluster": "old"}}
    )
    monkeypatch.setattr(evidence, "git", lambda *_a: "source-revision")
    output = tmp_path / "run"
    evidence.begin(output, config)
    monkeypatch.setattr(
        evidence, "snapshot", lambda _c: {"identities": {"cluster": "new"}}
    )
    with pytest.raises(ValueError, match="identity changed"):
        evidence.finish(output, config)
    assert not (output / "query-plan.json").exists()


def test_running_pod_with_old_identity_rejects_capture(monkeypatch):
    config = {"environment": "local-kind-owner-box", "version": "abc-after-datadog"}
    workloads = [
        {
            "kind": "Deployment",
            "metadata": {"name": name},
            "spec": {"selector": {"matchLabels": {"app": name}}},
        }
        for name in evidence.WORKLOADS
    ]
    pods = [
        {
            "metadata": {"name": f"{name}-pod", "labels": {"app": name}},
            "spec": {
                "containers": [
                    {
                        "name": "space",
                        "image": "local-image",
                        "env": [
                            {"name": "DD_ENV", "value": "prod"},
                            {"name": "DD_VERSION", "value": "old"},
                        ],
                    }
                ]
            },
        }
        for name in evidence.WORKLOADS
    ]

    def kube(_config, *args, **_kwargs):
        if args[:2] == ("get", "deploy,ds"):
            return json.dumps({"items": workloads})
        if args[:2] == ("get", "pods"):
            return json.dumps({"items": pods})
        return "ok"

    monkeypatch.setattr(evidence, "verify", lambda _c: {"backend": "saas"})
    monkeypatch.setattr(evidence, "kube", kube)
    with pytest.raises(ValueError, match="Stale SPACE identity"):
        evidence.snapshot(config)
