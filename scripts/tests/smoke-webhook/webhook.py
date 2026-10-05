#!/usr/bin/env python3
"""Tiny MutatingAdmissionWebhook for the SPACE node-rollout smoke test.

When active, every smoke-user pod created in the `sandboxes` namespace receives:
  - toleration: {key: space.pplx.net/smoke-pool, operator: Exists, effect: NoSchedule}
  - nodeSelector entry: {space.pplx.net/smoke-pool: <configured-pool>}

This lets smoke-test sandboxes land on the <configured-pool> nodes (which carry the
smoke-pool taint) while the webhook is inactive regular sandbox pods cannot
schedule there.

Lifecycle: deploy → populate sandboxes → teardown. Never leave running.
"""

import base64
import json
import logging
import os
import ssl
from http.server import BaseHTTPRequestHandler, HTTPServer

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

SMOKE_POOL_TAINT_KEY = "space.pplx.net/smoke-pool"
SMOKE_POOL_LABEL_KEY = "space.pplx.net/smoke-pool"
SMOKE_POOL_LABEL_VALUE = os.environ["SMOKE_POOL_LABEL_VALUE"]
if not SMOKE_POOL_LABEL_VALUE.strip():
    raise ValueError("SMOKE_POOL_LABEL_VALUE must not be empty")

TOLERATION = {
    "key": SMOKE_POOL_TAINT_KEY,
    "operator": "Exists",
    "effect": "NoSchedule",
}


class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:  # noqa: N802
        # Always return a structured AdmissionResponse, even on parse errors —
        # dropping the connection causes kube-apiserver to time out, then the
        # webhook config's failurePolicy: Fail denies the pod with an opaque
        # "webhook call failed" message. A structured `allowed: False` gives
        # the operator a clear root cause.
        #
        # Deny on parse errors (not admit unmutated) to match deploy.sh's
        # failurePolicy: Fail intent: every failure mode that produces an
        # unmutated smoke pod should be loud, not silent. A bypass here
        # would defeat the isolation guarantee the webhook exists to enforce.
        uid = ""
        request_api_version = "admission.k8s.io/v1"
        try:
            length_hdr = self.headers.get("Content-Length")
            if length_hdr is None:
                raise ValueError("missing Content-Length header")
            length = int(length_hdr)
            review = json.loads(self.rfile.read(length))
            uid = review.get("request", {}).get("uid", "")
            request_api_version = review.get("apiVersion", "admission.k8s.io/v1")

            pod_spec = review.get("request", {}).get("object", {}).get("spec") or {}
            patch = _build_patch(pod_spec)
            patch_b64 = base64.b64encode(json.dumps(patch).encode()).decode()

            response = {
                "apiVersion": request_api_version,
                "kind": "AdmissionReview",
                "response": {
                    "uid": uid,
                    "allowed": True,
                    "patchType": "JSONPatch",
                    "patch": patch_b64,
                },
            }
            pod_name = (
                review.get("request", {})
                .get("object", {})
                .get("metadata", {})
                .get("generateName", "?")
            )
            log.info("mutated pod %s: %d ops", pod_name, len(patch))
        except Exception as exc:  # noqa: BLE001 — admission response must always go out
            log.warning("admission request failed to parse / build: %s", exc)
            response = {
                "apiVersion": request_api_version,
                "kind": "AdmissionReview",
                "response": {
                    "uid": uid,
                    "allowed": False,  # match deploy.sh failurePolicy: Fail
                    "status": {
                        "code": 500,
                        "message": f"smoke-webhook internal error: {exc}",
                    },
                },
            }

        body = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args: object) -> None:
        # Suppress default HTTP request logs; we log in do_POST instead.
        pass


def _build_patch(spec: dict) -> list[dict]:
    patch: list[dict] = []

    # Toleration: create the array if absent, otherwise append.
    if spec.get("tolerations") is None:
        patch.append({"op": "add", "path": "/spec/tolerations", "value": [TOLERATION]})
    else:
        patch.append({"op": "add", "path": "/spec/tolerations/-", "value": TOLERATION})

    # nodeSelector entry: create the map if absent, otherwise add the key.
    # JSON Patch encodes '/' in key names as '~1'.
    ns_key_escaped = SMOKE_POOL_LABEL_KEY.replace("~", "~0").replace("/", "~1")
    if spec.get("nodeSelector") is None:
        patch.append(
            {
                "op": "add",
                "path": "/spec/nodeSelector",
                "value": {SMOKE_POOL_LABEL_KEY: SMOKE_POOL_LABEL_VALUE},
            }
        )
    else:
        patch.append(
            {
                "op": "add",
                "path": f"/spec/nodeSelector/{ns_key_escaped}",
                "value": SMOKE_POOL_LABEL_VALUE,
            }
        )

    return patch


def main() -> None:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain("/tls/tls.crt", "/tls/tls.key")

    server = HTTPServer(("0.0.0.0", 8443), WebhookHandler)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)

    log.info(
        "smoke-webhook listening on :8443 — mutating sandboxes namespace pods "
        "with smoke-pool toleration + nodeSelector=%s",
        SMOKE_POOL_LABEL_VALUE,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
