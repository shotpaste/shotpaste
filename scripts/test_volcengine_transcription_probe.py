"""Protocol and billing-safety regression tests; no network or credentials."""
import io
import json
import tempfile
import unittest
import uuid
from pathlib import Path

from volcengine_transcription_probe import ASRProbe, NoRedirect, ProbeFailure, credential, persist, validate_result


def result():
    return {"audio_info": {"duration": 1000}, "result": {
        "text": "测试", "utterances": [{"text": "测试", "start_time": 100,
        "end_time": 900, "additions": {"speaker": "1"}}]}}


class Response(io.BytesIO):
    def __init__(self, body, code="20000000", status=200):
        super().__init__(json.dumps(body).encode())
        self.status = status
        self.headers = {"X-Api-Status-Code": code, "X-Tt-Logid": "test-log"}


class Opener:
    def __init__(self, *responses):
        self.responses = list(responses)
        self.requests = []

    def open(self, request, timeout):
        self.requests.append(request)
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


class ProbeTests(unittest.TestCase):
    def test_report_reservation_cannot_overwrite_another_submission(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            persist(path, {"request_id": "first"}, create_only=True)
            with self.assertRaises(ProbeFailure):
                persist(path, {"request_id": "second"}, create_only=True)
            self.assertEqual(json.loads(path.read_text())["request_id"], "first")
            self.assertEqual(len(list(Path(directory).iterdir())), 1)

    def test_credential_control_characters_and_embedded_spaces_rejected(self):
        for value in ("", "a\nb", "a\rb", "a\tb", "a b", "a\x00b", "密钥", "x" * 4097):
            with self.subTest(value_length=len(value)), self.assertRaises(ProbeFailure):
                credential(value)
        self.assertEqual(credential(" test-key \n"), "test-key")

    def test_redirect_never_forwards_authentication(self):
        self.assertIsNone(NoRedirect().redirect_request(None, None, 307, None, {}, "https://example.com"))

    def test_query_uses_returned_task_id_and_auto_language(self):
        returned_id = str(uuid.uuid4())
        opener = Opener(Response({"task_id": returned_id}), Response({}, "20000002"), Response(result()))
        with tempfile.TemporaryDirectory() as directory:
            report = ASRProbe("test-key", opener, lambda _: None).run(Path(directory) / "report.json")
        self.assertEqual(report["outcome"], "passed")
        self.assertEqual(opener.requests[1].get_header("X-api-request-id"), returned_id)
        body = json.loads(opener.requests[0].data)
        self.assertNotIn("language", body["audio"])
        self.assertTrue(body["request"]["enable_auto_lang"])
        self.assertEqual(json.loads(opener.requests[1].data), {})
        self.assertNotIn("test-key", json.dumps(report))

    def test_http_failure_cannot_be_success_even_with_success_business_code(self):
        opener = Opener(Response({"task_id": str(uuid.uuid4())}, status=403))
        with tempfile.TemporaryDirectory() as directory:
            report = ASRProbe("test-key", opener, lambda _: None).run(Path(directory) / "report.json")
        self.assertEqual(report["outcome"], "submit_rejected_or_uncertain")
        self.assertEqual(len(opener.requests), 1)

    def test_live_submit_without_task_id_queries_original_request(self):
        opener = Opener(Response({}), Response(result()))
        with tempfile.TemporaryDirectory() as directory:
            report = ASRProbe("test-key", opener, lambda _: None).run(Path(directory) / "report.json")
        self.assertEqual(report["outcome"], "passed")
        self.assertIsNone(report["task_id"])
        self.assertEqual(opener.requests[1].get_header("X-api-request-id"), report["request_id"])

    def test_interrupted_submit_is_persisted_and_resume_only_queries(self):
        opener = Opener(OSError("contains-secret-and-url"))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            failed = ASRProbe("test-key", opener, lambda _: None).run(path)
            self.assertEqual(failed["outcome"], "transport_failed")
            self.assertNotIn("contains-secret", path.read_text())
            resumed = Opener(Response({}, "45000001"))
            ASRProbe("test-key", resumed, lambda _: None).run(path, resume=True)
            self.assertTrue(resumed.requests[0].full_url.endswith("/query"))
            self.assertEqual(resumed.requests[0].get_header("X-api-request-id"), failed["request_id"])
            with self.assertRaisesRegex(ProbeFailure, "existing_report"):
                ASRProbe("test-key").run(path)

    def test_server_error_message_never_persisted(self):
        opener = Opener(Response({"message": "secret-url"}, "45000030"))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            ASRProbe("test-key", opener, lambda _: None).run(path)
            self.assertNotIn("secret-url", path.read_text())

    def test_result_rejects_invalid_types_and_time_ranges(self):
        for field, value in (("start_time", True), ("start_time", -1), ("end_time", 2000),
                             ("end_time", "900"), ("end_time", 50), ("text", "")):
            body = result()
            body["result"]["utterances"][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ProbeFailure):
                validate_result(body)

    def test_missing_utterances_and_audio_info_rejected(self):
        for body in ({}, {"result": {"text": "partial"}},
                     {"audio_info": {"duration": 1000}, "result": {"text": "partial"}}):
            with self.assertRaises(ProbeFailure):
                validate_result(body)

    def test_result_preserves_part_scoped_speaker_and_times(self):
        parsed = validate_result(result())
        self.assertEqual(parsed["utterances"][0]["speaker_within_part"], "1")
        self.assertEqual(parsed["utterances"][0]["start_ms"], 100)


if __name__ == "__main__":
    unittest.main()
