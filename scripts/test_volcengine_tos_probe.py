import types
import unittest
import tempfile
import json
from pathlib import Path
from unittest.mock import patch

from volcengine_tos_probe import cleanup_only, safe_sdk_error, validate_report_reference, validate_resources, verify_deleted
from volcengine_transcription_probe import ASRProbe, ProbeFailure


class TOSProbeTests(unittest.TestCase):
    def test_resumed_setup_and_cleanup_reject_foreign_object_reference(self):
        resources = {"bucket": "shotpaste-tmp-poc-123456abcdef-debug", "prefix": "transcription/v1/123456abcdef/"}
        report = {**resources, "object_key": "transcription/v1/other-installation/" + "1" * 36 + "/sample.mp3"}
        with self.assertRaisesRegex(ProbeFailure, "unsafe_cleanup_reference"):
            validate_report_reference(resources, report)

    def test_cleanup_sdk_failure_is_redacted_and_preserves_pending_receipt(self):
        resources = {"installation": "123456abcdef", "region": "cn-beijing",
                     "bucket": "shotpaste-tmp-poc-123456abcdef-debug", "prefix": "transcription/v1/123456abcdef/"}
        class Client:
            def __init__(self, *args, **kwargs): pass
            def delete_object(self, *args):
                raise Exception("Authorization=secret; https://signed.example/?secret")
            def close(self): pass
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            path.write_text(json.dumps({**resources, "object_key": resources["prefix"] + "1" * 36 + "/sample.mp3",
                                        "outcome": "passed", "cleanup": "pending"}))
            with patch.dict("sys.modules", {"tos": types.SimpleNamespace(TosClientV2=Client)}):
                report = cleanup_only(resources, path, "fixture-ak", "fixture-sk")
            self.assertEqual(report["cleanup"], "pending")
            self.assertEqual(report["cleanup_error"], {"code": "tos_failed", "http": None})
            self.assertNotIn("secret", path.read_text())

    def test_resource_scope_cannot_take_over_an_existing_business_bucket(self):
        resource = {"installation": "123456abcdef", "region": "cn-beijing",
                    "bucket": "shotpaste-tmp-poc-123456abcdef-debug",
                    "prefix": "transcription/v1/123456abcdef/"}
        validate_resources(resource)
        for field, value in (("bucket", "business"), ("prefix", ""), ("region", "evil.example")):
            with self.assertRaises(ProbeFailure):
                validate_resources({**resource, field: value})

    def test_sdk_exception_never_exposes_payload_or_signed_url(self):
        error = Exception("https://secret-url")
        error.code = "contains-secret"
        error.status_code = 403
        self.assertEqual(safe_sdk_error(error), {"code": "tos_failed", "http": 403})

    def test_deleted_head_without_json_requires_bucket_to_exist(self):
        class ServerError(Exception):
            status_code = 404
        fake_tos = types.SimpleNamespace(exceptions=types.SimpleNamespace(TosServerError=ServerError))
        class Client:
            bucket_checked = False
            def head_object(self, bucket, key):
                raise ServerError()
            def head_bucket(self, bucket):
                self.bucket_checked = True
        client = Client()
        with patch.dict("sys.modules", {"tos": fake_tos}):
            verify_deleted(client, "bucket", "key")
        self.assertTrue(client.bucket_checked)

    def test_existing_object_is_not_cleaned(self):
        class ServerError(Exception):
            status_code = 404
        fake_tos = types.SimpleNamespace(exceptions=types.SimpleNamespace(TosServerError=ServerError))
        client = types.SimpleNamespace(head_object=lambda *args: None)
        with patch.dict("sys.modules", {"tos": fake_tos}), self.assertRaises(ProbeFailure):
            verify_deleted(client, "bucket", "key")

    def test_staged_url_must_be_owned_official_tos_endpoint(self):
        for url in ("https://example.com/a.mp3", "http://shotpaste-tmp-test.tos-cn-beijing.volces.com/transcription/v1/a",
                    "https://shotpaste-tmp-test.tos-cn-beijing.volces.com.evil.test/transcription/v1/a"):
            with self.assertRaisesRegex(ProbeFailure, "invalid_staged_endpoint"):
                ASRProbe("test-key").run("unused.json", staged_audio_url=url)


if __name__ == "__main__":
    unittest.main()
